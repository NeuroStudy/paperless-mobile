"""Gate lossless batch Dart/Python map and render parity for generated crops."""
import argparse
import json
from pathlib import Path
import numpy as np
import dart_reference as ref


def difference(expected, actual):
    assert expected.shape==actual.shape,(expected.shape,actual.shape)
    d=np.abs(expected.astype('float64')-actual)
    return dict(mae=float(d.mean()),max=float(d.max()),different_values=int((d!=0).sum()))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest',type=Path)
    parser.add_argument('native_root',type=Path)
    parser.add_argument('--baseline',action='store_true')
    parser.add_argument('--output',type=Path)
    args=parser.parse_args();results={}
    for case in json.loads(args.manifest.read_text()):
        name=case['name'];source=ref.read(args.manifest.parent/case['input'])
        profile=ref.analyze(source,not args.baseline)
        folder=args.native_root/name
        result={'output':difference(ref.render(source,profile),ref.read(folder/'native-output.png'))}
        metadata=json.loads((folder/'profile.json').read_text())
        result['contrast_difference']=abs(profile['contrast']-metadata['contrast'])
        for key in ['paper','protection','cleanup']:
            if profile.get(key) is not None:
                actual=np.frombuffer((folder/f'native-{key}.bin').read_bytes(),'uint8')
                result[key]=difference(profile[key].ravel(),actual)
        if not args.baseline:
            result['without_cleanup']=difference(ref.render(source,dict(profile,cleanup=None)),ref.read(folder/'native-without-cleanup.png'))
        assert result['contrast_difference']<1e-12,(name,result)
        assert all(value['max']==0 for key,value in result.items() if isinstance(value,dict)),(name,result)
        results[name]=result
    target=args.output or args.native_root/'python-parity.json'
    target.write_text(json.dumps(results,indent=2))
    print(json.dumps(results,indent=2))


if __name__=='__main__':main()
