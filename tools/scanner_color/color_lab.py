"""Offline scanner color workbench. See README.md; no app or personal fixtures required."""
from pathlib import Path
import argparse, json, time
import cv2
import numpy as np
from PIL import Image, ImageDraw
from collections import deque

METHODS = {
    "baseline": "baseline",
    "expanded-mask": "dilate_2",
    "luminance-chroma": "luma_15",
    "refined": "clean_5_1_.97_safe_hybrid",
}
OUT = Path("build/scanner-color-lab")

def read(path):
    return np.array(Image.open(path).convert('RGB'))

def save(name, image):
    Image.fromarray(np.uint8(np.clip(np.rint(image), 0, 255))).save(OUT / (name + '.png'))

def crop_render(image, max_edge=4096):
    h, w = image.shape[:2]
    scale = min(1., max_edge / max(w - 1, h - 1))
    ow, oh = max(2, round((w - 1) * scale)), max(2, round((h - 1) * scale))
    src = np.float32([[0, 0], [w - 1, 0], [w - 1, h - 1], [0, h - 1]])
    dst = np.float32([[0, 0], [ow - 1, 0], [ow - 1, oh - 1], [0, oh - 1]])
    return cv2.warpPerspective(image, cv2.getPerspectiveTransform(src, dst), (ow, oh), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)

def closing(image, k):
    radius = max(1, int(k * min(1, max(image.shape[:2]) / 768) + .5) // 2)
    k = radius * 2 + 1
    return cv2.morphologyEx(image, cv2.MORPH_CLOSE, np.ones((k, k), np.uint8), borderType=cv2.BORDER_REPLICATE)

def dilate(mask, r):
    return cv2.dilate(mask.astype('uint8'), np.ones((r*2+1, r*2+1), np.uint8)).astype(bool)

def fill(image, mask):
    h, w = mask.shape
    data = bytearray(image.tobytes())
    known = bytearray((~mask).astype('uint8').tobytes())
    queue = deque(i for i, v in enumerate(known) if v)
    while queue:
        i = queue.popleft()
        for n in (i-1 if i%w else -1, i+1 if i%w+1<w else -1, i-w if i>=w else -1, i+w if i+w<w*h else -1):
            if n >= 0 and not known[n]:
                data[n*3:n*3+3] = data[i*3:i*3+3]
                known[n] = 1
                queue.append(n)
    current = np.frombuffer(data, dtype='uint8').reshape(h, w, 3).copy()
    for _ in range(12):
        values = ((current[1:-1,:-2].astype('uint16') + current[1:-1,2:] + current[:-2,1:-1] + current[2:,1:-1] + 2) // 4).astype('uint8')
        current[1:-1,1:-1] = np.where(mask[1:-1,1:-1,None], values, current[1:-1,1:-1])
    return current

def masks(image, raw_reference=False):
    h,w = image.shape[:2]
    fine, broad = closing(image,15), closing(image,31)
    reference = np.percentile((image if raw_reference else broad).reshape(-1,3),90,axis=0,method='inverted_cdf')
    ratios = fine.astype(float)/np.maximum(reference,1)
    invalid = (np.ptp(ratios,axis=2) > .12) | ((broad.astype(int)-fine).max(axis=2) > 18)
    lum = image.astype(int).sum(axis=2)
    pl = fine.astype(int).sum(axis=2)
    edges = np.zeros((h,w),bool)
    edges[:,1:] = np.abs(image[:,1:].astype(int)-image[:,:-1]).sum(axis=2)>120
    for y in range(0,h,16):
        for x in range(0,w,16):
            sl = np.s_[y:y+16,x:x+16]
            if np.mean(lum[sl]<pl[sl]*.78)>.4 and edges[sl].mean()>.45: invalid[sl]=True
    panel = (pl < reference.mean()*3*.97).astype('uint8')
    count, labels, stats, _ = cv2.connectedComponentsWithStats(panel, connectivity=4)
    for label in range(1,count):
        x,y,pw,ph,area = stats[label]
        if x>1 and y>1 and x+pw-1<w-2 and y+ph-1<h-2 and .005*w*h<area<.4*w*h and area>.9*pw*ph:
            invalid[labels==label]=True
    return fine,broad,reference,invalid

def luma_profile(image, radius=15):
    fine,broad,reference,invalid = masks(image)
    if reference.mean()<90 or np.ptp(reference)/reference.mean()>.35 or invalid.mean()>.45:
        return None,1.08,invalid,invalid
    h,w = image.shape[:2]
    gray=np.mean(image.astype('float32'),axis=2).round().astype('uint8')
    light=closing(gray,15)
    # Protect actual filled rectangles separately from ink that morphology already removed.
    panels=np.zeros((h,w),bool)
    count,labels,stats,_=cv2.connectedComponentsWithStats((light<reference.mean()*.97).astype('uint8'),connectivity=4)
    for label in range(1,count):
        x,y,pw,ph,area=stats[label]
        if x>1 and y>1 and x+pw-1<w-2 and y+ph-1<h-2 and .005*w*h<area<.4*w*h and area>.9*pw*ph:
            panels[labels==label]=True
    light=fill(np.repeat(light[:,:,None],3,axis=2),dilate(panels,2))[:,:,0]
    valid=(gray>=closing(gray,15)*.98) & ~dilate(invalid,2)
    chroma=image.astype('float32')/np.maximum(gray[:,:,None],1)
    weight=cv2.boxFilter(valid.astype('float32'),-1,(radius*2+1,radius*2+1),normalize=False,borderType=cv2.BORDER_REPLICATE)
    color=cv2.boxFilter(chroma*valid[:,:,None],-1,(radius*2+1,radius*2+1),normalize=False,borderType=cv2.BORDER_REPLICATE)/np.maximum(weight[:,:,None],1)
    color[weight==0]=reference/reference.mean()
    paper=np.clip(color*light[:,:,None],0,255).round().astype('uint8')
    corrected=np.minimum(255,image.astype(float)*255/np.maximum(paper,1))
    gray=corrected.mean(axis=2)
    ink_values=gray[(gray>=20)&(gray<=190)&(np.ptp(corrected,axis=2)<40)&~invalid]
    contrast=np.clip(207/(255-np.percentile(ink_values,10,method='inverted_cdf')),1.08,1.6) if len(ink_values)>.002*gray.size else 1.08
    return cv2.medianBlur(paper,3),float(contrast),~valid,invalid

def profile(image, variant):
    if variant.startswith('luma_'): return luma_profile(image,int(variant.split('_')[1]))
    fine,broad,reference,invalid = masks(image,'hybrid' in variant)
    if reference.mean()<90 or np.ptp(reference)/reference.mean()>.35 or invalid.mean()>.45:
        return None,1.08,invalid,invalid
    brightness = np.floor(broad.mean(axis=2))
    varying = np.percentile(brightness,90,method='inverted_cdf')-np.percentile(brightness,10,method='inverted_cdf')>6
    if variant.startswith('clean_'):
        parts=variant.split('_')
        _,size,radius,threshold = parts[:4]
        size,radius,threshold=int(size),int(radius),float(threshold)
        gray=image.astype(float).mean(axis=2).round().astype('uint8')
        light=closing(gray,size)
        panels=np.zeros(gray.shape,bool)
        count,labels,stats,_=cv2.connectedComponentsWithStats((fine.mean(axis=2)<reference.mean()*.97).astype('uint8'),connectivity=4)
        h,w=gray.shape
        for label in range(1,count):
            x,y,pw,ph,area=stats[label]
            if x>1 and y>1 and x+pw-1<w-2 and y+ph-1<h-2 and .005*w*h<area<.4*w*h and area>.9*pw*ph:
                panels[labels==label]=True
        if len(parts)>4:
            # Large colored/photographic areas are content. Use the broad estimate
            # so a few colored text strokes cannot turn surrounding paper into a panel.
            chroma=broad.astype(float)/np.maximum(reference,1)
            if 'hybrid' in parts: chroma=chroma/np.maximum(chroma.mean(axis=2,keepdims=True),.01)
            panels |= np.ptp(chroma,axis=2)>(.35 if 'hybrid' in parts else .12)
            lum=image.astype(int).sum(axis=2); pl=fine.astype(int).sum(axis=2)
            edges=np.zeros((h,w),bool);edges[:,1:]=np.abs(image[:,1:].astype(int)-image[:,:-1]).sum(axis=2)>120
            for y in range(0,h,16):
                for x in range(0,w,16):
                    sl=np.s_[y:y+16,x:x+16]
                    if np.mean(lum[sl]<pl[sl]*.78)>.4 and edges[sl].mean()>.45: panels[sl]=True
        invalid |= panels
        if invalid.mean()>.45:
            return None,1.08,invalid,invalid
        # Only discard ink and actual filled panels, not a broad band at each shadow edge.
        ink=gray < light*threshold
        if 'hybrid' in parts: ink |= gray < closing(gray,15)*.80
        missing=dilate(ink,radius) | dilate(panels,2)
        if varying and (~missing).mean()<.05:
            return None,1.08,missing,panels
        paper=fill(image,missing)
    elif variant=='baseline':
        missing=dilate(invalid,2) | np.any(image < fine*.97,axis=2)
        paper=closing(fill(image,missing),15)
    else:
        radius=int(variant.split('_')[1])
        ink = np.any(image < fine*.97,axis=2)
        missing=dilate(invalid|ink,radius)
        paper=fill(image,missing)
        if 'close' in variant: paper=closing(paper,15)
        if 'blur' in variant: paper=cv2.GaussianBlur(paper,(0,0),2)
    if not varying: paper[:]=reference
    corrected=np.minimum(255,image.astype(float)*255/np.maximum(paper,1))
    gray=corrected.mean(axis=2).round()
    ink_values=gray[(gray>=20)&(gray<=190)&(np.ptp(corrected,axis=2)<40)&~invalid]
    contrast=np.clip(207/(255-np.percentile(ink_values,10,method='inverted_cdf')),1.08,1.6) if len(ink_values)>.002*gray.size else 1.08
    return cv2.medianBlur(paper,3),float(contrast),missing,(dilate(panels,2) if variant.startswith('clean_') else invalid)

def apply(image, paper, contrast, toe=0, protection=None):
    if paper is None: return np.clip(image.astype(float)*1.08-20.4,0,255).round().astype('uint8')
    field=cv2.resize(paper,(image.shape[1],image.shape[0]),interpolation=cv2.INTER_LINEAR)
    corrected=np.minimum(1,image.astype('float32')/np.maximum(field,63.75))
    if toe:
        # A common factor across RGB preserves color direction; dark ink stays unchanged.
        deficit=1-corrected
        d=deficit.max(axis=2)
        t=np.clip((d-toe/3)/(toe*2),0,1)
        factor=t*t*(3-2*t)
        if protection is not None:
            factor=np.maximum(factor,cv2.resize(protection.astype('float32'),(image.shape[1],image.shape[0])))
        corrected=1-deficit*factor[:,:,None]
    return np.clip(255*(1-(1-corrected)*contrast),0,255).round().astype('uint8')

def metrics(image, mask):
    p=image.astype(float)[mask]
    return {'paper_deficit':round(float((255-p.mean(axis=1)).mean()),3),
            'paper_chroma':round(float(np.ptp(p,axis=1).mean()),3),
            'paper_not_white_pct':round(float(np.mean(p.min(axis=1)<248)*100),3),
            'paper_yellow_pct':round(float(np.mean((p[:,0]+p[:,1])/2-p[:,2]>5)*100),3)}

def sheet(images,name,crop=None,scale=.9):
    views=[]
    for label,im in images:
        if crop: im=im[crop[1]:crop[3],crop[0]:crop[2]]
        pic=Image.fromarray(im); pic=pic.resize((round(pic.width*scale),round(pic.height*scale)))
        view=Image.new('RGB',(pic.width,pic.height+30),'#dddddd'); view.paste(pic,(0,30))
        ImageDraw.Draw(view).text((8,8),label,fill='black')
        views.append(view)
    result=Image.new('RGB',(sum(v.width for v in views),max(v.height for v in views)),'#aaaaaa')
    x=0
    for view in views: result.paste(view,(x,0)); x+=view.width
    result.save(OUT/(name+'.jpg'),quality=95)

def crop_argument(value):
    try:
        box = tuple(int(v) for v in value.split(","))
        if len(box) != 4 or min(box[:2]) < 0 or min(box[2:]) < 2:
            raise ValueError()
        return box
    except ValueError:
        raise argparse.ArgumentTypeError("Expected x,y,width,height with positive dimensions")


def read_crop(path, box):
    image = read(path)
    if box:
        x, y, w, h = box
        if x + w > image.shape[1] or y + h > image.shape[0]:
            raise ValueError("Crop is outside the input image")
        image = image[y:y+h, x:x+w]
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--crop", type=crop_argument)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--reference-crop", type=crop_argument)
    parser.add_argument("--native", type=Path, help="Optional native PNG export to compare numerically")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--methods", nargs="+", choices=METHODS, default=list(METHODS))
    args = parser.parse_args()
    global OUT
    OUT = args.output
    OUT.mkdir(parents=True, exist_ok=True)
    source = read_crop(args.input, args.crop)
    small, full = crop_render(source, 768), crop_render(source)
    save("source", full)
    # This candidate-paper mask is fixed from the input, never selected from an
    # output. It is a diagnostic, not ground truth for printed panels or lost ink.
    gray = cv2.cvtColor(small, cv2.COLOR_RGB2GRAY)
    fixed = ~dilate(gray.astype(float) < closing(gray, 15) * .975, 3)
    fixed = cv2.resize(fixed.astype("uint8"), (full.shape[1], full.shape[0]), interpolation=cv2.INTER_NEAREST).astype(bool)
    fixed[:15] = False; fixed[-15:] = False; fixed[:,:15] = False; fixed[:,-15:] = False
    if not fixed.any():
        raise ValueError("No candidate paper pixels; use a document crop")
    stats, images, outputs = {}, [], {}
    for name in args.methods:
        start = time.perf_counter()
        paper, contrast, missing, protected = profile(small, METHODS[name])
        analyzed = time.perf_counter()
        output = apply(full, paper, contrast, .025 if name == "refined" else 0, protected)
        rendered = time.perf_counter()
        outputs[name] = output
        save(name, output)
        stats[name] = {**metrics(output, fixed), "contrast": contrast,
                       "analysis_s": round(analyzed-start, 3), "render_s": round(rendered-analyzed, 3)}
        if paper is not None:
            save(name + "-paper-map", paper)
        save(name + "-excluded-samples", missing * 255)
        save(name + "-protected-content", protected * 255)
        images.append((name, output))
    if args.reference:
        reference = read_crop(args.reference, args.reference_crop)
        reference = cv2.resize(reference, (full.shape[1], full.shape[0]))
        save("reference", reference)
        # Screenshots can differ in geometry/encoding; these are approximate,
        # not registered PSNR/SSIM comparisons or proof of content preservation.
        stats["reference"] = metrics(reference, fixed)
        images.append(("Reference (resized)", reference))
    if args.native:
        native = read(args.native)
        expected = outputs.get("refined")
        if expected is None or native.shape != expected.shape:
            raise ValueError("Native comparison requires refined output with identical dimensions")
        difference = np.abs(native.astype(float) - expected)
        stats["native_agreement"] = {"rgb_mae": float(difference.mean()), "rgb_p99": float(np.percentile(difference,99))}
    sheet(images, "comparison", scale=min(1, 1800 / sum(im.shape[1] for _, im in images)))
    (OUT / "metrics.json").write_text(json.dumps(stats, indent=2), encoding="utf-8")
    print(json.dumps(stats, indent=2))


if __name__ == "__main__":
    main()
