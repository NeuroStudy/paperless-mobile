"""Deterministic refinement gate and personal-photo diagnostics (all outputs ignored)."""
import argparse
import json
import time
from pathlib import Path
import cv2
import numpy as np
import dart_reference as ref


def write(path, image):
    cv2.imwrite(str(path), image.astype('uint8'))


def synthetic(scale=1):
    h,w=768,576
    image=np.full((h,w,3),250,'uint8')
    masks={name:np.zeros((h,w),'uint8') for name in ['dark','faint','punctuation','rules','signature','dirt','fold']}
    def text(mask, value, words, origin, size=.55, thickness=1):
        glyphs=np.zeros((h,w),'uint8')
        cv2.putText(glyphs,words,origin,cv2.FONT_HERSHEY_SIMPLEX,size,255,thickness,cv2.LINE_AA)
        masks[mask]=np.maximum(masks[mask],glyphs)
        coverage=glyphs.astype(float)/255
        image[:]=ref.rounded(image*(1-coverage[:,:,None])+value*coverage[:,:,None]).astype('uint8')
    for y in range(80,330,34):
        text('dark',40,'Account 0123 123.45, EUR:',(45,y))
        text('faint',220,'faint edge; . , : 19.95',(305,y),.35)
    text('faint',225,'A complete faint sentence 0123.',(50,366),.55)
    text('punctuation',218,'. , : ; ! ? 1.25 0.01',(50,404),.55)
    for y in [450,474,498]:
        cv2.line(masks['rules'],(55,y),(510,y),255,1)
    for x in [55,160,290,510]:
        cv2.line(masks['rules'],(x,450),(x,498),255,1)
    image[masks['rules']>0]=225
    pts=np.array([(60,570),(86,550),(100,574),(123,548),(112,571),(190,555),(260,570),(320,550)])
    cv2.polylines(masks['signature'],[pts],False,255,1,cv2.LINE_AA)
    cov=masks['signature'].astype(float)/255
    image[:]=ref.rounded(image*(1-cov[:,:,None])+220*cov[:,:,None]).astype('uint8')
    yy,xx=np.mgrid[:h,:w]
    dirt=19*np.exp(-((xx-370)/20)**2-((yy-575)/14)**2)
    masks['dirt'][(abs(xx-370)<18)&(abs(yy-575)<12)]=255
    fold=np.zeros((h,w),float)
    for x in range(40,535):
        center=645+int(2*np.sin(x/23));width=1+(x//17)%4
        for y in range(center-width,center+width+1):
            fold[y,x]=16+9*(1-abs(y-center)/(width+1))
    masks['fold'][fold>8]=255
    image=ref.rounded(np.clip(image.astype(float)-dirt[:,:,None]-fold[:,:,None],0,255)).astype('uint8')
    if scale!=1:
        image=cv2.resize(image,None,fx=scale,fy=scale,interpolation=cv2.INTER_NEAREST)
        masks={k:cv2.resize(v,None,fx=scale,fy=scale,interpolation=cv2.INTER_NEAREST) for k,v in masks.items()}
    return image,masks


def measure(before,after,masks):
    result={}
    before_gray=before.mean(axis=2).astype('float64')
    after_gray=after.mean(axis=2).astype('float64')
    kernel=np.ones((11,11),'uint8')
    before_local=cv2.dilate(before_gray,kernel)-before_gray
    after_local=cv2.dilate(after_gray,kernel)-after_gray
    for name,mask in masks.items():
        pixels=mask>127
        if name in ('dirt','fold'):
            b=(255-before.mean(axis=2))[pixels].mean();a=(255-after.mean(axis=2))[pixels].mean()
            result[name]=dict(before=float(b),after=float(a),reduction=float(1-a/b) if b else 0)
        else:
            pixels=(mask>0)&(before_local>2)
            bd=before_local[pixels];ad=after_local[pixels]
            result[name]=dict(coverage=float(np.mean(ad>=bd*.95)),contrast_retention=float(np.sum(ad)/max(1,np.sum(bd))),max_change=int(np.abs(after.astype(int)-before)[pixels].max()),measured_pixels=int(pixels.sum()),excluded_near_white=int(((mask>0)&(before_local<=2)).sum()))
    return result


def gates(result):
    for name,value in result.items():
        if name in ('dirt','fold'):
            assert value['reduction'] >= .30,(name,value)
        elif name!='seconds':
            assert value['coverage'] >= .99,(name,value)
            assert value['contrast_retention'] >= .95,(name,value)
            # Aggregate coverage must not conceal a lost decimal or rule pixel.
            if name in ('dark','punctuation','rules'):
                assert value['max_change']==0,(name,value)


def red_metrics(image,truth):
    p=image[truth].astype(float)
    return dict(red_dominance_min=float(np.min(p[:,2]-np.maximum(p[:,0],p[:,1]))),
                yellow_fraction=float(np.mean((p[:,1]>p[:,2]-35)&(p[:,2]>130))),
                green_blue_spread_max=float(np.max(np.abs(p[:,1]-p[:,0]))))


def save_case(out,name,source,baseline,refined,profile=None,masks=None):
    folder=out/name;folder.mkdir(parents=True,exist_ok=True)
    write(folder/'input.png',source);write(folder/'dart-baseline.png',baseline);write(folder/'refined.png',refined)
    for key in ['paper','protection','missing','cleanup','cleanup_protection','rules']:
        if profile is not None and profile.get(key) is not None:
            value=profile[key]
            write(folder/f'{key}.png',value.astype('uint8')*(255 if value.dtype==bool or key=='protection' else 1))
    if masks:
        for key,value in masks.items():write(folder/f'truth-{key}.png',value)
    thumb=cv2.hconcat([source,baseline,refined]);write(folder/'comparison.png',thumb)
    return folder


def native_rule_cases(out):
    results={}
    for amplitude in [12,25]:
        h,w=1536,1152;y,x=np.mgrid[:h,:w]
        shade=23*np.exp(-((x-250)/100)**2-((y-400)/60)**2)
        source=ref.rounded(250-shade[:,:,None]+np.zeros((h,w,3))).astype('uint8')
        source[400,200:301]-=amplitude
        profile=ref.analyze(source,True)
        before=ref.render(source,dict(profile,cleanup=None));after=ref.render(source,profile)
        xs=np.arange(200,301);b=before.mean(axis=2);a=after.mean(axis=2)
        bc=(b[396,xs]+b[404,xs])/2-b[400,xs]
        ac=(a[396,xs]+a[404,xs])/2-a[400,xs]
        result=dict(local_contrast_before=float(bc.mean()),local_contrast_after=float(ac.mean()),
                    contrast_retention=float(ac.mean()/bc.mean()),coverage=float(np.mean(ac>=.95*bc)),
                    changed_pixels=int(np.sum(before[400,xs,0]!=after[400,xs,0])))
        assert result['coverage']>=.99 and result['contrast_retention']>=.95,result
        name=f'native-pale-rule-{amplitude}'
        save_case(out,name,source,before,after,profile)
        write(out/name/'rule-detail.png',cv2.resize(cv2.hconcat([before[380:421,180:321],after[380:421,180:321]]),None,fx=3,fy=3,interpolation=cv2.INTER_NEAREST))
        results[name]=result
    return results


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=Path('build/scanner-color-refinement'))
    parser.add_argument('--photos',type=Path)
    args=parser.parse_args();out=args.output;out.mkdir(parents=True,exist_ok=True)
    stats={};manifest=[]
    for scale in [1,2]:
        source,masks=synthetic(scale)
        begin=time.perf_counter();baseline=ref.analyze(source);old=ref.render(source,baseline)
        profile=ref.analyze(source,True);new=ref.render(source,profile)
        name=f'synthetic-{scale}x';save_case(out,name,source,old,new,profile,masks)
        result=measure(old,new,masks);result['seconds']=time.perf_counter()-begin
        stats[name]=result;manifest.append(dict(name=name,input=f'{name}/input.png'));gates(result)
    # JPEG, edge/inset strips and warm/cool mixed illumination, known text masks.
    for inset in [0,24]:
        for tint_name,tint in [('neutral',[1,1,1]),('warm',[.86,.94,1]),('cool',[1,.94,.86])]:
            source,masks=synthetic()
            source[inset:inset+4,30:546]=[25,25,215]
            yy,xx=np.mgrid[:source.shape[0],:source.shape[1]]
            shade=1-.48/(1+np.exp((xx/source.shape[1]+.2*yy/source.shape[0]-.65)*16))
            source=np.clip(ref.rounded(source*shade[:,:,None]*np.array(tint)),0,255).astype('uint8')
            for quality in [100,80]:
                decoded=source if quality==100 else cv2.imdecode(cv2.imencode('.jpg',source,[cv2.IMWRITE_JPEG_QUALITY,quality])[1],cv2.IMREAD_COLOR)
                name=f'strip-{inset}-{tint_name}-q{quality}'
                base=ref.analyze(decoded);profile=ref.analyze(decoded,True)
                old=ref.render(decoded,base);new=ref.render(decoded,profile)
                no_cleanup=dict(profile,cleanup=None)
                reference=ref.render(decoded,no_cleanup)
                result=measure(reference,new,{k:v for k,v in masks.items() if k not in ('dirt','fold')})
                try:gates(result)
                except AssertionError:
                    save_case(out,name,decoded,reference,new,profile,masks)
                    print(name,flush=True)
                    raise
                truth=np.zeros(decoded.shape[:2],bool);truth[inset+1:inset+3,40:536]=True
                # JPEG color bleed is allowed; yellow/orange reversals are not.
                color=red_metrics(new,truth)
                assert color['red_dominance_min']>=70,color
                assert color['yellow_fraction']==0,color
                result['color']=color
                save_case(out,name,decoded,old,new,profile)
                stats[name]=result;manifest.append(dict(name=name,input=f'{name}/input.png'))
    # The full-resolution guard and low/high taper must not reverse a ramp.
    ramp=np.arange(7,66,dtype='uint8')
    source=np.repeat((255-ramp)[None,:,None],3,axis=2)
    profile=dict(paper=np.full((1,59,3),255,'uint8'),protection=None,cleanup=np.full((1,59),255,'uint8'),contrast=1.08)
    result=ref.render(source,profile)
    assert (np.diff(result[0,:,0].astype(int))<=0).all(),result.tolist()
    stats['darkness-ramp']=dict(monotonic=True,min_darkness=7,max_darkness=65)
    write(out/'darkness-ramp.png',cv2.resize(cv2.vconcat([source,result]),None,fx=8,fy=16,interpolation=cv2.INTER_NEAREST))
    stats.update(native_rule_cases(out))
    if args.photos:
        first=ref.read(args.photos/'1-115089.jpg')
        quad=np.float32([[78,348],[495,339],[517,980],[65,988]])
        target=np.float32([[0,0],[451,0],[451,640],[0,640]])
        first=cv2.warpPerspective(first,cv2.getPerspectiveTransform(quad,target),(452,641),flags=cv2.INTER_CUBIC,borderMode=cv2.BORDER_REPLICATE)
        base=ref.analyze(first);profile=ref.analyze(first,True)
        old=ref.render(first,base);new=ref.render(first,profile)
        save_case(out,'sparkasse',first,old,new,profile)
        valid=np.zeros(first.shape[:2],bool)
        # Handles and editor border are outside this fixed inset measurement.
        valid[1:11,28:420]=True
        integer=first.astype(int)
        red=valid&(integer[:,:,2]>integer[:,:,1]+35)&(integer[:,:,2]>integer[:,:,0]+35)
        assert red.any()
        stats['sparkasse']=dict(baseline=red_metrics(old,red),refined=red_metrics(new,red),red_pixels=int(red.sum()))
        assert stats['sparkasse']['refined']['yellow_fraction']==0,stats['sparkasse']
        assert stats['sparkasse']['refined']['red_dominance_min']>0,stats['sparkasse']
        write(out/'sparkasse'/'measurement-valid.png',valid.astype('uint8')*255)
        write(out/'sparkasse'/'strip-detail.png',cv2.resize(cv2.vconcat([first[:14,28:420],old[:14,28:420],new[:14,28:420]]),None,fx=3,fy=3,interpolation=cv2.INTER_NEAREST))
        manifest.append(dict(name='sparkasse',input='sparkasse/input.png'))
        third=ref.read(args.photos/'3-115093.jpg')[217:897,38:553]
        clean,cleanup,protection,rules=ref.cleanup_only(third)
        save_case(out,'photo3-cleanup-only',third,third,clean,dict(cleanup=cleanup,cleanup_protection=protection,rules=rules))
        fixed=np.zeros(third.shape[:2],'uint8');fixed[456-217:467-217,465-38:548-38]=255
        stats['photo3-cleanup-only']=measure(third,clean,{'fold':fixed})
        gates(stats['photo3-cleanup-only'])
        write(out/'photo3-cleanup-only'/'fixed-crease-mask.png',fixed)
        write(out/'photo3-cleanup-only'/'crease-detail.png',cv2.resize(cv2.vconcat([third[236:253,420:512],clean[236:253,420:512]]),None,fx=5,fy=5,interpolation=cv2.INTER_NEAREST))
        # Appearance reference, not pixel-matched truth.
        write(out/'photo4-appearance.png',ref.read(args.photos/'4-115104.jpg')[184:937,26:565])
        write(out/'photo2-reported-distortion.png',ref.read(args.photos/'2-115091.jpg')[213:250,75:550])
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2))
    (out/'parameters.json').write_text(json.dumps(ref.PARAMETERS,indent=2))
    (out/'metrics.json').write_text(json.dumps(stats,indent=2))
    print(json.dumps(stats,indent=2))


if __name__=='__main__':main()
