"""Compare current Dart baseline and frozen conservative refinement on an exact crop."""
import argparse
import json
import time
from pathlib import Path
import cv2
import numpy as np
import dart_reference as ref


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--native',type=Path,help='Dart export_refinement.dart output directory')
    parser.add_argument('--baseline-native',action='store_true',help='Compare export from pre-change Dart')
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    source=ref.read(args.input);stats={};profiles={}
    cv2.imwrite(str(args.output/'input.png'),source)
    for name,refined in [('dart-baseline',False),('conservative',True)]:
        start=time.perf_counter();profile=ref.analyze(source,refined);analyzed=time.perf_counter()
        output=ref.render(source,profile);end=time.perf_counter()
        cv2.imwrite(str(args.output/f'{name}.png'),output)
        profiles[name]=profile
        for key in ['paper','protection','missing','cleanup','cleanup_protection','rules']:
            if profile.get(key) is not None:
                value=profile[key]
                cv2.imwrite(str(args.output/f'{name}-{key}.png'),value.astype('uint8')*(255 if value.dtype==bool or key=='protection' else 1))
        stats[name]=dict(analysis_seconds=analyzed-start,render_seconds=end-analyzed,contrast=profile['contrast'],width=profile['width'],height=profile['height'])
    if args.native:
        name='dart-baseline' if args.baseline_native else 'conservative'
        expected=ref.read(args.output/f'{name}.png');native=ref.read(args.native/'native-output.png')
        assert expected.shape==native.shape,(expected.shape,native.shape)
        diff=np.abs(expected.astype(int)-native)
        comparisons=dict(rgb_mae=float(diff.mean()),rgb_max=int(diff.max()),different_values=int((diff!=0).sum()))
        profile=profiles[name]
        for key in ['paper','protection','cleanup']:
            path=args.native/f'native-{key}.bin'
            if path.exists() and profile.get(key) is not None:
                actual=np.frombuffer(path.read_bytes(),'uint8');expected=profile[key].ravel()
                assert actual.size==expected.size,(key,actual.size,expected.size)
                difference=np.abs(expected.astype(int)-actual)
                comparisons[f'{key}_mae']=float(difference.mean())
                comparisons[f'{key}_max']=int(difference.max())
        stats['native_parity']=comparisons
        assert comparisons['rgb_max']<=1,comparisons
    (args.output/'metrics.json').write_text(json.dumps(stats,indent=2))
    (args.output/'parameters.json').write_text(json.dumps(ref.PARAMETERS,indent=2))
    print(json.dumps(stats,indent=2))


if __name__=='__main__':main()
