#!/usr/bin/env python3
"""Build Phase 3's native app using CLI tools; no Xcode project/GUI required.

Private preview embeds the exact qualified Phase 2 archive. No account, game,
cache, or installed prefix is copied. Uses the tracked owner artwork by default; --icon accepts an ICNS override.
The bundle is named Recall; its identifier and data folder keep their original values.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
from build_portable_setup import MINIMUM_MACOS, build as build_setup
from derive_runtime import archive_minimum, check_archive, format_macos, parse_macos

ROOT=Path(__file__).resolve().parents[1]
# The bundle and executable name players see; Brand.swift holds the in-app
# copy. The bundle identifier keeps its original value so updates carry over.
APP_NAME='Recall'
APP_BUILD='38'
RESOURCES=('MosaicLogo.png','LinkedInMark.png','AuthorPhoto.jpg','Wordmark.png','WordmarkDark.png')
def run(*args):subprocess.run([str(a) for a in args],check=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def build(output,workspace,runtime_archive,icon=None,identity=None):
    release=json.loads((ROOT/'app/Resources/release.json').read_text())
    if sha(runtime_archive)!=release['runtimeSHA256']:raise ValueError('Unqualified runtime archive')
    # The worker rejects any file its manifest does not list, so check before shipping.
    if check_archive(runtime_archive)['version']!=release['runtimeVersion']:raise ValueError('Runtime archive names a different version')
    # Every engine binary must open on the app's minimum macOS (derive_runtime.py --minimum-macos re-stamps them).
    # An engine stamped older (1.1's 15.0) is fine: the app is what refuses older macOS.
    newest,declared=archive_minimum(runtime_archive)
    if newest>parse_macos(MINIMUM_MACOS) or parse_macos(declared)>parse_macos(MINIMUM_MACOS):
        raise ValueError(f'The runtime needs macOS {format_macos(newest)} (manifest: {declared}); the app supports {MINIMUM_MACOS}')
    if output.exists():raise ValueError('Choose a new output bundle; previous candidates are retained')
    helpers=output/'Contents/Helpers';resources=output/'Contents/Resources';macos=output/'Contents/MacOS'
    for directory in (helpers,resources,macos):directory.mkdir(parents=True)
    build_setup(helpers/'ow2-setup',ROOT/'runtime/toolchains/libarchive-3.7.7')
    shutil.move(helpers/'ow2-setup.build.json',output.parent/'worker-build.json')
    run('/usr/bin/swiftc','-file-prefix-map',str(ROOT)+'=/ow2-source','-O','-target','arm64-apple-macos'+MINIMUM_MACOS,'-parse-as-library',*sorted((ROOT/'app/Sources').glob('*.swift')),'-o',macos/APP_NAME)
    run('/usr/bin/swiftc','-file-prefix-map',str(ROOT)+'=/ow2-source','-O','-target','arm64-apple-macos'+MINIMUM_MACOS,ROOT/'scripts/portable_pipeline.swift','-o',helpers/'ow2-pipeline')
    native=workspace/'dxmt-source/src/winemetal/unix'
    # Compile only the exact accepted pipeline source, not an arbitrary checkout.
    accepted={'pipeline_cache.c': '56531ef6221f6be9a8e621c3df7f0b8c3faf5233a763c118a4ec97142b290f9e', 'pipeline_cache.h': '5e4558226c4e4144af5f199ffd435f6c94b04ff3c9f17714605eabc0abaea16f', 'pipeline_recipe.c': '47c3c7bbb4f9286c38de1316a7bc47300faad79dc0ae40be86292da93e889dc6', 'pipeline_recipe.h': '40f4193da8270d9f3f60b8306fa6f0680f3cf226e7e307625c7a795020f18af2'}
    sources=('pipeline_cache.c','pipeline_cache.h','pipeline_recipe.c','pipeline_recipe.h')
    for name in sources:
        if sha(native/name)!=accepted[name]:raise ValueError('Pipeline sources differ from accepted build: '+name)
    run('/usr/bin/clang','-ffile-prefix-map='+str(ROOT)+'=/ow2-source','-arch','x86_64','-mmacosx-version-min='+MINIMUM_MACOS,'-x','objective-c','-fblocks','-fno-objc-arc','-DDXMT_PIPELINE_CACHE_OFFLINE_TOOL','-O2','-dynamiclib',native/'pipeline_recipe.c',native/'pipeline_cache.c','-framework','Foundation','-framework','Metal','-framework','QuartzCore','-install_name','@rpath/libpipeline_prepare.dylib','-o',helpers/'libpipeline_prepare.dylib')
    run('/usr/bin/clang','-ffile-prefix-map='+str(ROOT)+'=/ow2-source','-arch','x86_64','-mmacosx-version-min='+MINIMUM_MACOS,'-x','objective-c','-fblocks','-fobjc-arc','-DDXMT_PIPELINE_CACHE_OFFLINE_TOOL','-O2','-I',native,ROOT/'scripts/pipeline_prepare.m','-x','none',helpers/'libpipeline_prepare.dylib','-Wl,-rpath,@executable_path','-framework','Foundation','-framework','Metal','-o',helpers/'pipeline-prepare')
    # Warms the game app's own shader cache from the learned pipelines (portable_pipeline.swift).
    run('/usr/bin/clang','-ffile-prefix-map='+str(ROOT)+'=/ow2-source','-arch','x86_64','-mmacosx-version-min='+MINIMUM_MACOS,'-x','objective-c','-fblocks','-fno-objc-arc','-O2','-I',native,ROOT/'scripts/pipeline_warm.m','-x','none',helpers/'libpipeline_prepare.dylib','-Wl,-rpath,@executable_path','-framework','Foundation','-framework','Metal','-o',helpers/'pipeline-warm')
    rosetta=helpers/'Rosetta Check.app/Contents';(rosetta/'MacOS').mkdir(parents=True)
    source=output.parent/'rosetta-check.c';source.write_text('int main(void) { return 0; }\n')
    run('/usr/bin/clang','-ffile-prefix-map='+str(ROOT)+'=/ow2-source','-arch','x86_64','-mmacosx-version-min='+MINIMUM_MACOS,source,'-o',rosetta/'MacOS/RosettaCheck')
    (rosetta/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.overwatch2mac.rosetta-check','CFBundleExecutable':'RosettaCheck','CFBundleName':'Rosetta Check','CFBundlePackageType':'APPL','LSUIElement':True,'LSMinimumSystemVersion':MINIMUM_MACOS}))
    run('/bin/cp','-c',runtime_archive,resources/release['runtimeArchive'])
    shutil.copy2(ROOT/'app/Resources/release.json',resources/'release.json')
    shutil.copy2(ROOT/'docs/candidate-parity-contract.json',resources/'candidate-parity-contract.json')
    # Notices from the actual reviewed runtime; kept readable without extraction.
    runtime_dir=runtime_archive.with_suffix('').with_suffix('')
    if (runtime_dir/'licenses').exists():shutil.copytree(runtime_dir/'licenses',resources/'Licenses')
    shutil.copy2(ROOT/'licenses/PROJECT-APACHE-2.0',resources/'PROJECT-LICENSE.txt')
    shutil.copy2(ROOT/'licenses/PROJECT-NOTICE',resources/'NOTICE.txt')
    shutil.copy2(ROOT/'licenses/GITHUB-MARK-NOTICE.txt',resources/'GITHUB-MARK-NOTICE.txt')
    shutil.copy2(ROOT/'licenses/PROJECT-LINKS-NOTICE.txt',resources/'PROJECT-LINKS-NOTICE.txt')
    for name in RESOURCES:
        shutil.copy2(ROOT/'app/Resources'/name,resources/name)
    if icon:shutil.copy2(icon,resources/'AppIcon.icns')
    else:
        iconset=output.parent/'AppIcon.iconset'
        run('/usr/bin/swift',ROOT/'scripts/app_icon.swift',ROOT/'app/Resources/AppIcon.png',iconset)
        run('/usr/bin/iconutil','-c','icns',iconset,'-o',resources/'AppIcon.icns')
    (output/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.overwatch2mac.launcher','CFBundleExecutable':APP_NAME,'CFBundleName':APP_NAME,'CFBundleDisplayName':APP_NAME,'CFBundlePackageType':'APPL','CFBundleShortVersionString':release['appVersion'],'CFBundleVersion':APP_BUILD,'CFBundleIconFile':'AppIcon','LSMinimumSystemVersion':MINIMUM_MACOS,'NSHighResolutionCapable':True,'LSMultipleInstancesProhibited':True,'NSPrincipalClass':'NSApplication','NSHumanReadableCopyright':'Independent community project. Not affiliated with or endorsed by Blizzard Entertainment or Apple.'}))
    for binary in (helpers/'libpipeline_prepare.dylib',helpers/'pipeline-prepare',helpers/'pipeline-warm'):
        run('/usr/bin/strip','-S','-x',binary)
    if identity:
        for binary in (helpers/'ow2-setup',helpers/'ow2-pipeline',helpers/'libpipeline_prepare.dylib',helpers/'pipeline-prepare',helpers/'pipeline-warm',rosetta.parent):
            run('/usr/bin/codesign','--force','--options','runtime','--timestamp','--sign',identity,binary)
        run('/usr/bin/codesign','--force','--options','runtime','--timestamp','--sign',identity,output)
        run('/usr/bin/codesign','--verify','--deep','--strict',output)
    proof={'app_version':release['appVersion'],'app_build':APP_BUILD,'candidate_contract_sha256':sha(resources/'candidate-parity-contract.json'),'runtime_sha256':sha(resources/release['runtimeArchive']),'pipeline_sources':{name:sha(native/name) for name in sources},'source_files':{str(p.relative_to(ROOT)):sha(p) for p in sorted((ROOT/'app').rglob('*')) if p.is_file()},'signed':bool(identity),'files':{str(p.relative_to(output)):sha(p) for p in output.rglob('*') if p.is_file()}}
    output.with_suffix('.build.json').write_text(json.dumps(proof,indent=2)+'\n')
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--workspace',type=Path,default=ROOT/'runtime/phase-2');p.add_argument('--runtime-archive',type=Path,default=ROOT/'runtime/phase-2/artifacts/phase2-20260927.1.tar.gz');p.add_argument('--icon',type=Path);p.add_argument('--identity')
    a=p.parse_args();build(a.output.resolve(),a.workspace.resolve(),a.runtime_archive.resolve(),a.icon,a.identity)
