#!/usr/bin/env python3
"""Build the native setup worker with system libraries and pinned public headers."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request
from candidate_contract import verify_generated

ROOT = Path(__file__).resolve().parents[1]
HEADERS = {'archive.h':'11c373fab05e8f017220aff1d89cec3cf32146b44d6cb56aeb12e968bc3b950b',
           'archive_entry.h':'510ae3e21a800403bb1c8d413d5ddabaee0b38facb8491b60bb6da55f84f4695'}


def build(output, headers):
    verify_generated()
    headers.mkdir(parents=True,exist_ok=True)
    for name,expected in HEADERS.items():
        target=headers/name
        if not target.exists():
            data=urllib.request.urlopen('https://raw.githubusercontent.com/libarchive/libarchive/v3.7.7/libarchive/'+name,timeout=30).read()
            if hashlib.sha256(data).hexdigest()!=expected:raise ValueError('Header hash mismatch')
            target.write_bytes(data)
        if hashlib.sha256(target.read_bytes()).hexdigest()!=expected:raise ValueError('Header hash mismatch')
    output.parent.mkdir(parents=True,exist_ok=True)
    subprocess.run(['/usr/bin/clang','-O2','-fobjc-arc','-Wall','-Wextra','-Werror',
        '-Wno-deprecated-declarations','-ffile-prefix-map='+str(ROOT)+'=/ow2-source','-mmacosx-version-min=26.0','-I',str(headers),
        str(ROOT/'scripts/portable_setup.m'),'-framework','Foundation','-framework','AppKit','-larchive','-o',str(output)],check=True)
    output.with_suffix('.build.json').write_text(json.dumps({'headers':HEADERS,
        'sources':{name:hashlib.sha256((ROOT/'scripts'/name).read_bytes()).hexdigest() for name in ('portable_setup.m','portable_session.h','portable_preferences.h','portable_retina.h','portable_diagnostics.h','candidate_contract.generated.h')},
        'binary_sha256':hashlib.sha256(output.read_bytes()).hexdigest(),
        'links':'System Foundation, CommonCrypto and libarchive; no bundled Python'},indent=2)+'\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--headers',type=Path,default=ROOT/'runtime/toolchains/libarchive-3.7.7')
    args=parser.parse_args();build(args.output.resolve(),args.headers.resolve())
