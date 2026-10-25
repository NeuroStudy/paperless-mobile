"""Explicit BGR reference for shared Dart scanner analysis/rendering.

Unlike color_lab's historical experiments this does not rectify/resample its
input before analysis. All round operations match positive Dart double.round.
"""
from collections import deque
import cv2
import numpy as np

PARAMETERS = dict(analysis_edge=768, color_spread=.35, darkness_min=8,
                  darkness_max=60, neutral_spread=18, strong_darkness=64,
                  reduction=.5, lift_cap=20, feather_radius=2,
                  fragment_gap=8, fragment_padding=3, small_mark_span=24,
                  rule_min_span=24, rule_center_tolerance=.65,
                  rule_thickness_range=1, rule_quantiles=[.05,.95],
                  local_window=5, local_delta=3, local_height_limit=24,
                  local_aspect_limit=8, local_page_width_limit=.8,
                  glyph_expansion=2, elongated_aspect=8,
                  elongated_density=.45, elongated_guard_expansion=2,
                  sparse_density=.45, final_protection_expansion=1,
                  confidence_steps=[0,85,170,255], upper_taper=12,
                  lower_lift_floor=8, version=1)


def rounded(a):
    return np.floor(np.asarray(a) + .5)


def read(path):
    image = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError(f'Cannot decode {path}')
    return image


def dilate(mask, rx, ry=None):
    ry = rx if ry is None else ry
    return cv2.dilate(mask.astype('uint8'), np.ones((2*ry+1, 2*rx+1), 'uint8')).astype(bool)


def percentile(a, fraction):
    return np.quantile(a, fraction, axis=0, method='inverted_cdf')


def components(mask):
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask.astype('uint8'), connectivity=4)
    return labels, stats[1:]


def fill(paper, missing):
    h, w = missing.shape
    data = bytearray(paper.tobytes())
    known = bytearray((~missing).astype('uint8').tobytes())
    queue = deque(i for i, v in enumerate(known) if v)
    while queue:
        i = queue.popleft()
        for n in (i-1 if i%w else -1, i+1 if i%w+1<w else -1,
                  i-w if i>=w else -1, i+w if i+w<w*h else -1):
            if n >= 0 and not known[n]:
                data[n*3:n*3+3] = data[i*3:i*3+3]
                known[n] = 1
                queue.append(n)
    current = np.frombuffer(data, 'uint8').reshape(h, w, 3).copy()
    for _ in range(12):
        values = ((current[1:-1,:-2].astype('uint16') + current[1:-1,2:] +
                   current[:-2,1:-1] + current[2:,1:-1] + 2) // 4).astype('uint8')
        current[1:-1,1:-1] = np.where(missing[1:-1,1:-1,None], values, current[1:-1,1:-1])
    return current


def normalized(image, paper):
    return np.minimum(255., image.astype('float64') * 255 / np.maximum(63.75, paper))


def stable_rule(local):
    ch,cw=local.shape
    horizontal=cw>=24 and cw>=4*ch
    vertical=ch>=24 and ch>=4*cw
    if not(horizontal or vertical):return False
    axis=local if horizontal else local.T
    lengths=axis.sum(axis=0);active=lengths>0
    centers=(axis*np.arange(axis.shape[0])[:,None]).sum(axis=0)[active]/lengths[active]
    return (active.mean()>=.95 and
            np.quantile(centers,.95)-np.quantile(centers,.05)<=.65 and
            np.quantile(lengths[active],.95)-np.quantile(lengths[active],.05)<=1)


def cleanup_map(corrected, protection):
    """Classify only bounded analysis pixels; uncertain sparse marks stay protected.

    Strong ink fragments create padded word boxes. Remaining weak components
    preserve small marks, sparse non-axis-aligned writing, and straight rules
    whose centre AND thickness remain stable. Broad dirt and irregular axis-
    aligned folds can receive cleanup. A distance ramp feathers toward content.
    """
    h, w = corrected.shape[:2]
    darkness = 255 - corrected.min(axis=2)
    spread = np.ptp(corrected, axis=2)
    strong = darkness >= PARAMETERS['strong_darkness']
    protected = protection.astype(bool) | dilate(strong, 2)
    fragments = dilate(strong, 4, 1)
    labels, stats = components(fragments)
    for x,y,cw,ch,area in stats:
        # Text and handwriting regions; keep boxes local, never span a page.
        if cw <= w*.8 and ch <= h*.15:
            protected[max(0,y-3):min(h,y+ch+3), max(0,x-3):min(w,x+cw+3)] = True
    # A shadow residual may connect many faint letters into one broad component.
    # Recover their thin local strokes before classifying absolute darkness.
    gray=rounded(corrected.mean(axis=2)).astype('uint8')
    local=cv2.morphologyEx(gray,cv2.MORPH_CLOSE,np.ones((5,5),'uint8'),borderType=cv2.BORDER_REPLICATE)
    local_ink=(local.astype(int)-gray>=3)&(darkness>=8)
    # Dense elongated residuals can contain tiny morphological fragments; those
    # fragments must not make an irregular crease look like punctuation.
    residual_labels,residual_stats=components((darkness>=8)&~protected)
    elongated=np.zeros((h,w),bool)
    for label,(x,y,cw,ch,area) in enumerate(residual_stats,1):
        if max(cw,ch)>=24 and (cw>=8*ch or ch>=8*cw) and area>=cw*ch*.45:
            sl=np.s_[y:y+ch,x:x+cw]
            elongated[sl]|=residual_labels[sl]==label
    elongated=dilate(elongated,2)
    local_labels,local_stats=components(local_ink)
    glyphs=np.zeros((h,w),bool)
    for label,(x,y,cw,ch,area) in enumerate(local_stats,1):
        sl=np.s_[y:y+ch,x:x+cw]
        member=local_labels[sl]==label
        if stable_rule(member):
            glyphs[sl]|=member
            continue
        if ch<24 and cw <= 8*ch and cw < w*.8:
            if not np.any(elongated[sl]&member):
                glyphs[sl]|=member
    protected|=dilate(glyphs,2)
    weak = (darkness >= 8) & ~protected
    labels, stats = components(weak)
    rules = np.zeros((h,w), bool)
    for label,(x,y,cw,ch,area) in enumerate(stats,1):
        sl = np.s_[y:y+ch,x:x+cw]
        local = labels[sl] == label
        small = max(cw,ch) < 24
        horizontal = cw >= 24 and cw >= 4*ch
        vertical = ch >= 24 and ch >= 4*cw
        straight = stable_rule(local)
        sparse_writing = area < cw*ch*.45
        # Compact, tiny uncertain marks include decimal points and punctuation.
        if small or straight or sparse_writing:
            protected[sl] |= local
            if straight:
                rules[sl] |= local
    protected = dilate(protected, 1)
    # Two-pixel bounded ramp, integer-distance morphology is identical in Dart.
    near = dilate(protected, 1)
    far = dilate(protected, 2)
    confidence = np.full((h,w), 255, 'uint8')
    confidence[far] = 170
    confidence[near] = 85
    confidence[protected] = 0
    eligible = (darkness >= 8) & (darkness <= 60) & (spread <= 18)
    confidence[~eligible] = 0
    return confidence, protected, rules


def analyze(image, refined=False):
    sh, sw = image.shape[:2]
    scale = min(1.,768/max(sw,sh))
    w,h = max(2,int(sw*scale+.5)),max(2,int(sh*scale+.5))
    small = cv2.resize(image,(w,h),interpolation=cv2.INTER_AREA)
    def closing(a, size):
        radius = max(1,int(size*min(1.,max(sw,sh)/768)+.5)//2)
        return cv2.morphologyEx(a,cv2.MORPH_CLOSE,np.ones((2*radius+1,2*radius+1),'uint8'),borderType=cv2.BORDER_REPLICATE)
    fine,broad = closing(small,15),closing(small,31)
    reference = percentile(small.reshape(-1,3),.9)
    fallback = dict(paper=None,protection=None,cleanup=None,contrast=1.08,width=0,height=0)
    if reference.mean()<90 or np.ptp(reference)/reference.mean()>.35:
        return fallback
    brightness = broad.astype('uint16').sum(axis=2)//3
    varying = percentile(brightness.ravel(),.9)-percentile(brightness.ravel(),.1)>6
    ratios = fine.astype(float)/np.maximum(1,reference)
    invalid = (np.ptp(ratios,axis=2)>.12) | ((broad.astype(int)-fine).max(axis=2)>18)
    color = broad.astype(float)/np.maximum(1,reference)
    content = np.ptp(color,axis=2)/np.maximum(.01,color.mean(axis=2))>.35
    if refined:
        raw = small.astype(float)/np.maximum(1,reference)
        content |= np.ptp(raw,axis=2)/np.maximum(.01,raw.mean(axis=2))>.35
    lum=small.astype('uint16').sum(axis=2); fl=fine.astype('uint16').sum(axis=2)
    edges=np.zeros((h,w),bool)
    edges[:,1:]=np.abs(small[:,1:].astype(int)-small[:,:-1]).sum(axis=2)>120
    for y in range(0,h,16):
        for x in range(0,w,16):
            sl=np.s_[y:y+16,x:x+16]
            if np.mean(lum[sl]<fl[sl]*.78)>.4 and edges[sl].mean()>.45:
                content[sl]=True
    labels, stats = components(fl < reference.mean()*3*.97)
    for label,(x,y,cw,ch,area) in enumerate(stats,1):
        if x>1 and y>1 and x+cw-1<w-2 and y+ch-1<h-2 and .005*w*h<area<.4*w*h and area>.9*cw*ch:
            content[labels==label]=True
    invalid |= content
    if invalid.mean()>.45:
        return fallback
    protection=dilate(content,2)
    missing=protection.copy()
    if varying:
        gray=((lum+1)//3).astype('uint8')
        ink=(gray<closing(gray,5)*.97) | (gray<closing(gray,15)*.8)
        missing |= dilate(ink,1)
        if (~missing).mean()<.05:
            return fallback
        paper=fill(small,missing)
    else:
        paper=np.broadcast_to(reference,small.shape).astype('uint8').copy()
    corrected=np.minimum(255.,small.astype(float)*255/np.maximum(1,paper))
    values=rounded(corrected.mean(axis=2))
    ink_values=values[(~invalid)&(values>=20)&(values<=190)&(np.ptp(corrected,axis=2)<40)]
    contrast=float(np.clip(207/(255-percentile(ink_values,.1)),1.08,1.6)) if ink_values.size>w*h*.002 else 1.08
    paper=cv2.medianBlur(paper,3)
    cleanup=cleanup_protection=rules=None
    if refined:
        cleanup,cleanup_protection,rules=cleanup_map(normalized(small,paper),protection)
    return dict(paper=paper,protection=protection.astype('uint8'),cleanup=cleanup,contrast=contrast,width=w,height=h,
                missing=missing,content=content,cleanup_protection=cleanup_protection,rules=rules,small=small,reference=reference)


def sample(field, width, height):
    """Dart's pixel-centred double bilinear sampling (not OpenCV INTER_LINEAR)."""
    h,w=field.shape[:2]
    sx,sy=w/width,h/height
    xx=np.clip((np.arange(width)+.5)*sx-.5,0,w-1)
    yy=np.clip((np.arange(height)+.5)*sy-.5,0,h-1)
    x0=np.floor(xx).astype(int); x1=np.minimum(w-1,x0+1); dx=xx-x0
    y0=np.floor(yy).astype(int); y1=np.minimum(h-1,y0+1); dy=yy-y0
    if field.ndim==3:
        dx=dx[:,None];dy=dy[:,None,None]
    else:
        dy=dy[:,None]
    return (field[y0[:,None],x0]*(1-dx)+field[y0[:,None],x1]*dx)*(1-dy)+(field[y1[:,None],x0]*(1-dx)+field[y1[:,None],x1]*dx)*dy


def render(image, profile):
    if profile['paper'] is None:
        return np.clip(rounded(image.astype(float)*1.08-20.4),0,255).astype('uint8')
    h,w=image.shape[:2]
    corrected=normalized(image,sample(profile['paper'],w,h))
    darkness=255-corrected.min(axis=2)
    t=np.clip((darkness-2.125)/12.75,0,1)
    factor=t*t*(3-2*t)
    if profile['protection'] is not None:
        factor=np.maximum(factor,sample(profile['protection'],w,h))
    if profile.get('cleanup') is not None:
        confidence=sample(profile['cleanup'],w,h)/255
        # Recheck the ORIGINAL pixel after normalization; no cleanup reaches dark
        # cores or colored marks hidden by the bounded analysis downsampling.
        eligible=(darkness>=8)&(darkness<=60)&(np.ptp(corrected,axis=2)<=18)
        lift=np.minimum(np.minimum(darkness*.5,20),np.maximum(0,darkness-8))
        lift*=np.clip((60-darkness)/12,0,1)
        reduction=lift/np.maximum(1,darkness)*confidence*eligible
        factor*=1-reduction
    return np.clip(rounded(255+(corrected-255)*factor[:,:,None]*profile['contrast']),0,255).astype('uint8')


def cleanup_only(image):
    # Independent diagnostic for an already-enhanced page: no second analysis,
    # white balance, contrast, or existing highlight curve is applied.
    h,w=image.shape[:2]
    scale=min(1.,768/max(w,h));sw=max(2,int(w*scale+.5));sh=max(2,int(h*scale+.5))
    small=cv2.resize(image,(sw,sh),interpolation=cv2.INTER_AREA)
    cleanup,protection,rules=cleanup_map(small.astype(float),np.zeros((sh,sw),'uint8'))
    d=255-image.min(axis=2).astype(float)
    lift=np.minimum(np.minimum(d*.5,20),np.maximum(0,d-8))
    lift*=np.clip((60-d)/12,0,1)
    eligible=(d>=8)&(d<=60)&(np.ptp(image,axis=2)<=18)
    reduction=lift/np.maximum(1,d)*sample(cleanup,w,h)/255*eligible
    out=np.clip(rounded(255+(image.astype(float)-255)*(1-reduction[:,:,None])),0,255).astype('uint8')
    return out,cleanup,protection,rules
