#!/usr/bin/env python3
"""Reject non-source assets and recognizable credentials before commit/push."""
import argparse
import hashlib
from pathlib import PurePosixPath
import re
import subprocess
import sys

# Owner-supplied, visually reviewed artwork; metadata removed before tracking.
# Keep these exceptions narrow: exact reviewed asset paths and hashes only.
# Every hash ever reviewed stays listed: a pre-push scan covers whole history
# when a new tag or branch is pushed, so older commits must still pass.
APP_ICON_PATH = 'app/Resources/AppIcon.png'
# The Recall icon (2026-10-01); earlier Overwatch 2 Mac artwork stays listed.
APP_ICON_SHA256 = 'cf35f2034332cb5071b7b1e057fe4c5e767e73dafb8f13e2f40ca5ac993d044e'
PREVIOUS_APP_ICON_SHA256 = {'512923aab9fb505b84eec26289bf36cd228c4741db42ce6fefdeba6892d265d3',
                            '7eb25ba04e3d0060c3379e955da0b121e11935939881bcf07946abeb8da75f63'}

REVIEWED_ASSETS = {
    APP_ICON_PATH: {APP_ICON_SHA256, *PREVIOUS_APP_ICON_SHA256},
    # README banner, the owner's light and dark lockups, the author photo.
    'app/Resources/Banner.png': {'95cf86bd46fdd56f2765ac8498191a187c4888c4d1de73c34ace8fdaa706a3d9'},
    'app/Resources/Wordmark.png': {'214af160c00a88ae0260a7a31e19c210096233278d683c84da8d1c31a04153a7',
                                   '8ca131902bd73f9bbbf5a9fe88e0639a14795c245c7390f030748bc330a4ef0a'},
    'app/Resources/WordmarkDark.png': {'8237bef1d48e0ec229e9ed589657e97f1feb22151e8f6d87e1a7943e72fc8617',
                                       '1703fc952ed83b6e1c96d7fc4d7e6f1d15d7874900f1d37eabf8715efe8b0773'},
    'app/Resources/AuthorPhoto.jpg': {'e747a105c7c3af851b78ca01bf1a037e6e089f70908a4b093c7ba566ff883f19',
                                      'f8aeb51a72f48b9f3156c51a875f519b9cede050749ed78e9e1ae555364daf94'},
    'app/Resources/MosaicLogo.png': {'7d596a74bfaefce23a7cad874d7b14a016b2ae00b2c551260596623b32791aba'},
    'app/Resources/LinkedInMark.png': {'3c0149f26168b5fe0f43e68664abe40341a6443b3cd435d18a73e12f64f8b600'},
    # README-only art (2026-10-02): the CrossOver comparison chart, the round
    # author photo and the support buttons, rendered from HTML with no metadata.
    'app/Resources/ReadmeBenchmark.png': {'31a24738bb1a0ffadbace07c1f376e6bb2a35ee739cd7d8ca6ef782b0d854bab', 'b58c75717c5b505f4b84efd13fe78ca4751e77a26bccc8c5219d6de9a46cb60e'},
    'app/Resources/AuthorPhotoRound.png': {'36401eb5d72ff67cba56969843fc597d1d20b78f75872c6a5320a34638eda65d'},
    'app/Resources/ButtonCoffee.png': {'e1a140debece937489f23c835dd8774533d9f09f892e4c0d39b90d168747d4bd'},
    'app/Resources/ButtonMosaic.png': {'ea5da8825e2c7b0994d3740c10abe4dc01f0b191466edd8c34bb4bc6e927ef0c'},
    'app/Resources/ButtonLinkedIn.png': {'1f2c35468d22bb0a8aec2808b1d6a1946833d03ff0180acc8cc8607ee570f8f2'},
    'app/Resources/HowItWorksStack.png': {'bcdd822c8001984822d71c047d1a64543e7ada9de9d720fec63f9afe3e0357cf'},
    'app/Resources/HowItWorksMouse.png': {'409eef05ccad7ad05e8075d57bf9debc0dc01e053c6061827d035f63164c372e'},
    'app/Resources/HowItWorksShaders.png': {'0fedfb291cfd28805a2bfc4b3fbd9db6d639f00b5a424c572ea1e06c1ab44016'},
    'app/Resources/MetalFXResults.png': {'6134cbfa9676bc38e5e6bfe2c2f5fc3228e75370c2caf1ee4acb1bc7431a34c3'},
    'app/Resources/MetalFXPixels.png': {'9d82b2c18c24b2a7e5f517ae4321c740e854a6576725289316bd56b36dcaaa94'},
    'app/Resources/MetalFXChain.png': {'6f41debaf566b679dd1f9d0a4b1834d6e410a94cb446bb783a9593c429983528'},
}

MAX_BYTES = 2 * 1024 * 1024
SOURCE_SUFFIXES = {'.py', '.c', '.m', '.h', '.hpp', '.cpp', '.in', '.md', '.txt', '.swift'}
SECRETS = [
    ('private key', rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'),
    ('GitHub credential', rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b'),
    ('AWS access key', rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    ('Slack credential', rb'\bxox[baprs]-[A-Za-z0-9-]{20,}\b'),
]


def git(*args):
    return subprocess.check_output(['git', *args])


def check_path(name, mode):
    path = PurePosixPath(name)
    if mode not in ('100644', '100755'):
        raise ValueError('symlink, submodule or unsupported file mode')
    if any(part in ('runtime', 'downloads', 'logs', '__pycache__') or
           part.endswith(('.app', '.dSYM')) for part in path.parts):
        raise ValueError('local runtime, logs or generated asset')
    allowed = False
    if len(path.parts) == 1:
        allowed = name in ('.gitignore', '.gitattributes', 'COMMIT_MESSAGE.txt') or path.suffix in ('.md', '.command')
    elif path.parts[0] in ('scripts', 'tests'):
        allowed = path.suffix in SOURCE_SUFFIXES
    elif path.parts[0] == 'app':
        allowed = name in REVIEWED_ASSETS or path.suffix in ('.swift', '.plist', '.json', '.md')
    elif path.parts[0] == 'config':
        allowed = path.suffix == '.conf'
    elif path.parts[0] == 'patches':
        allowed = path.suffix in ('.patch', '.md')
    elif path.parts[0] == 'docs':
        allowed = path.suffix in ('.md', '.json')
    elif path.parts[0] == 'licenses':
        allowed = True
    elif name in ('.githooks/pre-commit', '.githooks/pre-push'):
        allowed = True
    if not allowed:
        raise ValueError('outside the source/documentation allowlist')


def check_blob(data):
    if len(data) > MAX_BYTES:
        raise ValueError('file exceeds the 2 MiB source limit')
    if b'\0' in data:
        raise ValueError('binary payload')
    try:
        data.decode('utf-8')
    except UnicodeDecodeError:
        raise ValueError('non-UTF-8 payload') from None
    for label, pattern in SECRETS:
        if re.search(pattern, data):
            raise ValueError(label)


def entries(commit=None):
    output = git('ls-tree', '-rz', commit) if commit else git('ls-files', '--stage', '-z')
    for record in output.split(b'\0'):
        if not record:
            continue
        fields, name = record.split(b'\t', 1)
        parts = fields.decode().split()
        if commit:
            mode, kind, oid = parts
        else:
            mode, oid, stage = parts
            if stage != '0':
                raise ValueError('unresolved index conflict')
        yield name.decode(), mode, oid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pre-push', action='store_true')
    args = parser.parse_args()
    commits = [None]
    if args.pre_push:
        commits = []
        for line in sys.stdin:
            local_ref, local_sha, remote_ref, remote_sha = line.split()
            if local_sha == '0' * 40:
                continue
            revision = [local_sha] if remote_sha == '0' * 40 else [local_sha, '^' + remote_sha]
            commits.extend(git('rev-list', *revision).decode().splitlines())
    inspected = set()
    checked_files = 0
    for commit in dict.fromkeys(commits):
        for name, mode, oid in entries(commit):
            try:
                check_path(name, mode)
                if oid not in inspected:
                    data = git('cat-file', 'blob', oid)
                    if name in REVIEWED_ASSETS:
                        if hashlib.sha256(data).hexdigest() not in REVIEWED_ASSETS[name]:
                            raise ValueError('asset differs from reviewed artwork')
                    else:
                        check_blob(data)
                    inspected.add(oid)
                checked_files += 1
            except ValueError as error:
                # Report only the path and finding category, never the secret.
                raise SystemExit(f'Repository guard rejected {name}: {error}') from None
    print(f'Repository guard passed: {checked_files} file entries, {len(inspected)} unique source blobs.')


if __name__ == '__main__':
    main()
