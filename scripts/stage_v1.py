#!/usr/bin/env python3
"""Install or restore the validated private candidate with stopped Wine clients."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

import launch_cx26 as launch
import stage_dxmt_local as dxmt
import build_v1_window_driver as window

ROOT=launch.ROOT
ENGINE=ROOT/'runtime/soju-engine-dxmt-local'
PREFIX=ROOT/'runtime/prefix-dxmt-local'
STATE=ROOT/'logs/dxmt/v1-stage.json'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def write_json(path,data):
    temp=path.with_name('.v1-state-'+path.name)
    temp.write_text(json.dumps(data,indent=2)+'\n');os.replace(temp,path)
def replace(source,target):
    temporary=target.with_name('.v1-install-'+target.name)
    try:shutil.copy2(source,temporary);os.replace(temporary,target)
    finally:temporary.unlink(missing_ok=True)

def configuration_entries(original):
    entries=[]
    for group in ['scripts','config']:
        for source in sorted((original/group).iterdir()):
            if source.is_file():
                entries.append(dict(source=str(source.relative_to(original)),
                                    target=str(Path(group)/source.name),sha256=sha(source)))
    # Launch shortcuts also carry experimental options. Restoring libraries
    # without their saved shortcut can otherwise silently change the test mode.
    for source in sorted(original.glob('*.command')):
        entries.append(dict(source=source.name,target=source.name,sha256=sha(source)))
    source=original/'settings-before-v1.ini'
    entries.append(dict(source=source.name,
        target=str((PREFIX/'drive_c/users/Sikarugir/Documents/Overwatch/Settings/Settings_v0.ini').relative_to(ROOT)),
        sha256=sha(source)))
    return entries

def verify_recovery(data):
    backup=Path(data['backup']);original=Path(data['pre_phase_backup'])
    for entry in data['entries']:
        if entry['existed'] and sha(backup/entry['path'])!=entry['sha256']:
            raise RuntimeError('Rollback file failed hash verification')
    # Older candidates did not record configuration digests. Keep their recovery
    # available; new candidates verify scripts, profiles and settings as well.
    configs=data.get('configuration_entries')
    if configs is None:configs=configuration_entries(original)
    for entry in configs:
        if sha(original/entry['source'])!=entry['sha256']:
            raise RuntimeError('Rollback configuration failed hash verification')
    return configs

def restore_snapshot(data, configs, failure=False):
    backup=Path(data['backup']);original=Path(data['pre_phase_backup'])
    for entry in reversed(data['entries']):
        target=ROOT/entry['path']
        if entry['existed']:replace(backup/entry['path'],target)
        else:target.unlink(missing_ok=True)
    for entry in configs:replace(original/entry['source'],ROOT/entry['target'])
    if data.get('previous_stage'):
        write_json(STATE,data['previous_stage'])
    else:
        data['status']='rolled_back_after_install_failure' if failure else 'restored'
        write_json(STATE,data)

def install(replace_installed=False):
    previous=json.loads(STATE.read_text()) if STATE.exists() else None
    if STATE.exists() and json.loads(STATE.read_text()).get('status')=='installed':
        if not replace_installed:
            raise RuntimeError('This candidate is already staged; preserve its rollback before replacing it')
    elif replace_installed:
        raise RuntimeError('Replacement requires an installed candidate')
    manifest=dxmt.validate_build()
    patch=subprocess.check_output(['git','-C',str(window.ROOT/'runtime/source/dxmt-ow2'),'diff','--binary'])
    if hashlib.sha256(patch).hexdigest()!=manifest['patch_sha256']:raise RuntimeError('DXMT source differs from build')
    native=json.loads((window.BUILD/'manifest.json').read_text())
    driver=window.BUILD/'dlls/winemac.drv/winemac.so'
    if window.hashes()!=native['sources'] or sha(driver)!=native['driver_sha256']:raise RuntimeError('Window source differs from build')
    for name,expected in native['dependencies'].items():
        if sha(ENGINE/f'lib/wine/x86_64-unix/{name}.so')!=expected:raise RuntimeError('Native dependency changed')
    fullscreen=sorted((ROOT/'logs/dxmt').glob('v1-fullscreen-*/report.json'))[-1]
    proof=json.loads(fullscreen.read_text())
    if set(proof)!={'1080','1200'} or any(not row.get('assertions','').startswith('PASS:') for row in proof.values()):
        raise RuntimeError('Both fullscreen resolutions must pass the actual graphics fixture')
    identity=json.loads((fullscreen.parent/'build-identity.json').read_text())
    if identity['dxmt']!=manifest or identity['driver_sha256']!=native['driver_sha256']:
        raise RuntimeError('Fullscreen fixture tested a different build')
    launch.stop_clients()
    stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    backup=ROOT/'runtime/build-history'/('before-v1-install-'+stamp);backup.mkdir()
    backup_pointer='v1-correction-backup.json' if replace_installed else 'v1-backup.json'
    original=Path(json.loads((ROOT/'logs/dxmt'/backup_pointer).read_text())['backup'])
    if not (original/'settings-before-v1.ini').exists():
        raise RuntimeError('The complete pre-correction recovery snapshot is missing')
    entries=[]
    def save(path):
        relative=path.relative_to(ROOT);copy=backup/relative;copy.parent.mkdir(parents=True,exist_ok=True)
        exists=path.exists()
        if exists:shutil.copy2(path,copy)
        entries.append(dict(path=str(relative),existed=exists,sha256=sha(path) if exists else None))
    operations=[(dxmt.INSTALL/name,ENGINE/'lib/wine'/name) for name in dxmt.FILES]
    operations += [(dxmt.INSTALL/'x86_64-windows/winemetal.dll',PREFIX/'drive_c/windows/system32/winemetal.dll'),
                   (driver,ENGINE/'lib/wine/x86_64-unix/winemac.so'),
                   (dxmt.INSTALL/'build-manifest.json',ENGINE/'local-build-manifest.json'),
                   (window.BUILD/'manifest.json',ENGINE/'v1-window-manifest.json')]
    for _,target in operations:save(target)
    save(PREFIX/'drive_c/users/Sikarugir/Documents/Overwatch/Settings/Settings_v0.ini')
    pointer=ROOT/'logs/dxmt/current-source-stage.json';save(pointer)
    data=dict(status='installing',backup=str(backup),pre_phase_backup=str(original),entries=entries,
              dxmt=manifest,window=native,fullscreen_proof=str(fullscreen),
              configuration_entries=configuration_entries(original))
    if replace_installed:data['previous_stage']=previous
    write_json(STATE,data)
    try:
        for source,target in operations:
            replace(source,target)
            if sha(source)!=sha(target):raise RuntimeError('Installed hash mismatch')
        launch.validate_source_runtime(ENGINE,PREFIX,require_v1=True,allow_installing=True)
        from set_windowed_1080 import apply_preferences
        data['preferences']=apply_preferences(PREFIX/'drive_c/users/Sikarugir/Documents/Overwatch/Settings/Settings_v0.ini',backup,1080)
        (ROOT/'patches/dxmt-v1-private.patch').write_bytes(patch)
        data['status']='installed'
        write_json(pointer,dict(stage_manifest=str(STATE)))
        write_json(STATE,data)
    except BaseException:
        # Keep the installing marker if recovery itself fails: launch must not
        # proceed with a mixture of runtime, bridge and preference versions.
        configs=verify_recovery(data)
        restore_snapshot(data,configs,failure=True)
        raise
    print('V1 candidate installed and hashes verified. Battle.net is closed; launch with a v1 shortcut.')
    print(STATE)

def restore():
    data=json.loads(STATE.read_text())
    if data['status'] not in ('installed','installing'):raise RuntimeError('No installed or interrupted v1 candidate to restore')
    configs=verify_recovery(data)
    launch.stop_clients()
    restore_snapshot(data,configs)
    print('Previous runtime, launcher scripts, profile and saved window settings restored. Learned game caches retained.')
    print('Use Launch Battle.net - Source Build.command after recovery.')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--install',action='store_true');group.add_argument('--restore',action='store_true')
    parser.add_argument('--replace-installed',action='store_true',help='Preserve and replace the installed candidate using the pre-correction recovery snapshot.')
    args=parser.parse_args()
    if args.replace_installed and not args.install:parser.error('--replace-installed requires --install')
    install(args.replace_installed) if args.install else restore()
