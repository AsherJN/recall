#!/usr/bin/env python3
"""Actual Metal helper subset selection and malformed-selection rejection."""
import datetime
import json
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
import prepare_dxmt_pipelines as prep
prep.validate_helper()
proof=sorted((ROOT/'logs/dxmt').glob('offline-prepare-proof-*/cache'))[-1]
out=ROOT/'logs/dxmt'/('refresh-selection-proof-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
out.mkdir();reports={}
for name in ['subset','duplicate','malformed']:
    target=out/name;target.mkdir();cache=target/'cache'
    subprocess.run(['/bin/cp','-cR',str(proof),str(cache)],check=True)
    namespace=next(cache.glob('*/recipes')).parent
    learning={str(p.relative_to(namespace)):prep.sha(p) for group in ['recipes','libraries'] for p in (namespace/group).iterdir() if p.is_file()}
    keys=sorted(p.stem for p in (namespace/'recipes').glob('*.json'))[:2]
    prep.reset_cloned_archive(namespace)
    selection=keys if name=='subset' else [keys[0],keys[0]] if name=='duplicate' else ['invalid']
    data=prep.run_helper(cache,target,'prepare',namespace='offline-prepare-proof-v1',limit=2,budget=30000,selection=selection)
    if name=='subset':
        assert prep.archive_keys(namespace)==set(keys),data
        verified=prep.run_helper(cache,target,'verify',namespace='offline-prepare-proof-v1',limit=2,budget=30000)
        assert verified['prepared']==2 and verified['failures']==verified['archive_failures']==0,verified
    else:
        assert data['failures'] and data['prepared']==0,data
        assert not prep.archive_keys(namespace)
    assert all(prep.sha(namespace/p)==digest for p,digest in learning.items())
    reports[name]=data
    print(name,'PASS',flush=True)
(out/'report.json').write_text(json.dumps(reports,indent=2)+'\n')
print(out)
