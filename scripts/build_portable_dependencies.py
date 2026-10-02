#!/usr/bin/env python3
"""Build the runtime's small native dependency closure from pinned inputs.

Developer-only prerequisites: clang, make and pkg-config. Installation stays
inside --workspace; no Homebrew libraries enter the distributed payload.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

INPUTS = {
    'pkgconf-2.5.1.tar.xz': ('https://distfiles.dereferenced.org/pkgconf/pkgconf-2.5.1.tar.xz', 'cd05c9589b9f86ecf044c10a2269822bc9eb001eced2582cfffd658b0a50c243'),
    'nettle-3.10.2.tar.gz': ('https://ftp.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz', 'fe9ff51cb1f2abb5e65a6b8c10a92da0ab5ab6eaf26e7fc2b675c45f1fb519b5'),
    'gnutls-3.8.13.tar.xz': ('https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz', 'ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e'),
    'libinotify-20240724.tar.gz': ('https://github.com/libinotify-kqueue/libinotify-kqueue/releases/download/20240724/libinotify-20240724.tar.gz', '5cc3fb7af407b17b7daa871cc98bb882716c4b5c296fadfb66bfe86c37cc599c'),
    'MoltenVK-macos.tar': ('https://github.com/KhronosGroup/MoltenVK/releases/download/v1.2.9/MoltenVK-macos.tar', '93369586b116bc027ef7121fd713ff32fcd856febcb4622b6ba527edcadd68ea'),
}
WINE_SHA = 'ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872'


def sha(p):
    with p.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()


def build(work, jobs):
    if any(c.isspace() for c in str(work)):
        raise ValueError('Autoconf source workspace must not contain whitespace; installed runtime supports spaces')
    source = work / 'native-sources'; source.mkdir(parents=True, exist_ok=True)
    prefix = work / 'clean-deps'; prefix.mkdir(exist_ok=True)
    logs = work / 'build-logs'; logs.mkdir(exist_ok=True)
    for name, (url, expected) in INPUTS.items():
        archive = work / 'downloads' / name
        if not archive.exists():
            part = Path(str(archive) + '.part')
            subprocess.run(['/usr/bin/curl', '-fL', '--proto', '=https', '--proto-redir', '=https', '--retry', '2', '-o', str(part), url], check=True)
            if sha(part) != expected: raise ValueError('Download hash mismatch: ' + name)
            part.rename(archive)
        if sha(archive) != expected: raise ValueError('Input hash mismatch: ' + name)
        marker = source / (name + '.extracted')
        if not marker.exists():
            with tarfile.open(archive) as t: t.extractall(source, filter='data')
            marker.write_text(expected)
    wine = work / 'downloads/wine.tar.gz'
    if sha(wine) != WINE_SHA: raise ValueError('CodeWeavers source identity mismatch')
    gnu = work / 'gnu-source'
    if not (gnu / '.extracted').exists():
        with tarfile.open(wine) as t:
            t.extractall(gnu, members=[m for m in t.getmembers() if m.name.startswith(('sources/gnutls/gmp/', 'sources/gnutls/nettle/'))], filter='data')
        (gnu / '.extracted').write_text(WINE_SHA)
    env = os.environ.copy(); env.pop('DESTDIR', None)
    env.update(PATH=str(prefix / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin',
               CC='/usr/bin/clang -arch x86_64', CXX='/usr/bin/clang++ -arch x86_64',
               CFLAGS='-O2 -g0 -ffile-prefix-map=' + str(work) + '=/build/overwatch-2-mac',
               LDFLAGS='-L' + str(prefix / 'lib'), CPPFLAGS='-I' + str(prefix / 'include'),
               PKG_CONFIG_LIBDIR=str(prefix / 'lib/pkgconfig'), PKG_CONFIG_PATH='',
               MACOSX_DEPLOYMENT_TARGET='26.0')
    components = [
        ('pkgconf', source / 'pkgconf-2.5.1', []),
        ('gmp', gnu / 'sources/gnutls/gmp', ['--disable-cxx']),
        ('nettle', source / 'nettle-3.10.2', ['--disable-documentation']),
        ('gnutls', source / 'gnutls-3.8.13', ['--disable-doc', '--disable-tests', '--disable-tools', '--disable-cxx', '--disable-nls', '--disable-libdane', '--without-p11-kit', '--without-idn', '--without-tpm', '--without-tpm2', '--without-zlib', '--without-brotli', '--without-zstd', '--with-included-libtasn1', '--with-included-unistring', '--with-system-priority-file=']),
        # New SDKs expose fdclosedir only from macOS 26.4; use the upstream
        # compatibility path to retain the runtime's 26.0 deployment target.
        ('inotify', source / 'libinotify-20240724', ['ac_cv_func_fdclosedir=no']),
    ]
    old_proof = work / 'native-build-proof.json'
    previous_options = json.loads(old_proof.read_text()).get('configure_options', {}) if old_proof.exists() else {}
    for name, src, options in components:
        directory = work / ('native-build-' + name); directory.mkdir(exist_ok=True)
        if name == 'inotify':
            # This release's export-list argument is relative to the build cwd.
            shutil.copy2(src / 'libinotify.sym', directory / 'libinotify.sym')
        with (logs / (name + '.log')).open('w') as log:
            def run(args): subprocess.run([str(a) for a in args], cwd=directory, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            marker = directory / '.configuration.json'
            configuration = {'source': str(src), 'prefix': str(prefix), 'options': options,
                             'compiler': env['CC'], 'flags': env['CFLAGS']}
            changed = ((marker.exists() and json.loads(marker.read_text()) != configuration) or
                       (name in previous_options and previous_options[name] != options))
            if changed and (directory / 'Makefile').exists(): run(['make', 'clean'])
            if changed or not (directory / 'config.status').exists():
                run(['/usr/bin/arch', '-x86_64', src / 'configure', '--prefix=' + str(prefix), '--host=x86_64-apple-darwin', '--enable-shared', '--disable-static'] + options)
            marker.write_text(json.dumps(configuration, indent=2) + '\n')
            run(['make', '-j' + str(jobs)])
            run(['make', 'install'])
        print('Built native dependency: ' + name, flush=True)
        if name == 'pkgconf': env['PKG_CONFIG'] = str(prefix / 'bin/pkgconf')
    molten = source / 'MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib'
    subprocess.run(['/usr/bin/lipo', str(molten), '-thin', 'x86_64', '-output', str(prefix / 'lib/libMoltenVK.dylib')], check=True)
    licenses = prefix / 'licenses'; licenses.mkdir(exist_ok=True)
    for name, src, _ in components:
        target = licenses / name; target.mkdir(exist_ok=True)
        for p in src.iterdir():
            if p.is_file() and p.name.startswith(('COPYING', 'LICENSE', 'AUTHORS', 'NOTICE')): shutil.copy2(p, target / p.name)
    shutil.copy2(source / 'MoltenVK/LICENSE', licenses / 'MoltenVK-LICENSE')
    record = {'inputs': {n: {'url': v[0], 'sha256': v[1]} for n, v in INPUTS.items()},
              'gmp_source': {'archive_sha256': WINE_SHA, 'path': 'sources/gnutls/gmp', 'version': '6.3.0'},
              'configure_options': {n: opts for n, _, opts in components},
              'files': {p.name: sha(p) for p in (prefix / 'lib').glob('*.dylib')}}
    (work / 'native-build-proof.json').write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--workspace', type=Path, required=True)
    p.add_argument('--jobs', type=int, choices=range(1, 5), default=2)
    a = p.parse_args(); build(a.workspace.resolve(), a.jobs)
