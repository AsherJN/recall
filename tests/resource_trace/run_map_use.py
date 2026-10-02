#!/usr/bin/env python3
import csv
import json
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]
report={}
for arch in ['arm64','x86_64']:
    with tempfile.TemporaryDirectory(dir=ROOT/'runtime/build',prefix='map-use-') as tmp:
        d=Path(tmp)
        (d/'thread.hpp').write_text('#pragma once\n#include <thread>\nnamespace dxmt { using thread=std::thread; namespace this_thread { inline bool isInModuleDetachment(){return false;} } }\n')
        for name in ['dxmt_resource_log.hpp','dxmt_map_use.hpp']:
            (d/name).write_bytes((ROOT/'runtime/source/dxmt-ow2/src/dxmt'/name).read_bytes())
        common=['/usr/bin/clang++','-arch',arch,'-std=c++20','-Wall','-Wextra','-Werror','-I'+str(d),str(ROOT/'tests/resource_trace/map_use.cpp')]
        subprocess.run(common+['-fsanitize=address,undefined','-fno-omit-frame-pointer','-o',str(d/'sanitized')],check=True)
        subprocess.run([str(d/'sanitized'),str(d/'pairs'),'pairs'],check=True,timeout=20)
        summaries=[json.loads(p.read_text()) for p in d.glob('pairs-*.summary.json')]
        assert len(summaries)==1
        summary=summaries[0];ops=summary['operations']
        assert ops['mapped_use_immediate']['calls']==11,ops
        assert ops['mapped_use_deferred']['calls']==1
        assert ops['map_pair_issue']['calls']==10
        events=[r for p in d.glob('pairs-*.events.csv') for r in csv.DictReader(p.open())]
        mapped=[r for r in events if r['operation'].startswith('mapped_use_')]
        assert len(mapped)==3,mapped
        assert all(int(r['duration_ns'])>=4_000_000 and r['bytes_known']=='0' for r in mapped)
        assert any((int(r['detail'])>>32)!=int(r['thread_id']) for r in mapped)
        subprocess.run(common+['-O3','-o',str(d/'bench')],check=True)
        cost={}
        for mode in ['disabled','enabled']:
            cost[mode]=[float(subprocess.check_output([str(d/'bench'),str(d/f'{mode}{n}'),mode],text=True)) for n in range(3)]
        report[arch]=dict(summary=summary,ns_per_pair=cost)
        print(arch,'PASS:',cost,flush=True)
(ROOT/'logs/dxmt/v1-map-use-proof.json').write_text(json.dumps(report,indent=2)+'\n')
