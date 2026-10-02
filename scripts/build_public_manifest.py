#!/usr/bin/env python3
"""Generate the reviewed public export manifest (docs/public-export.json).

The manifest lists every file that reaches the public repository, pinned by
hash. Product source under app/, scripts/, tests/, patches/, config/ and
licenses/ is included from the Git index; engineering diaries, desktop
shortcuts, private PRDs, runtime data and logs are never listed. Public
documentation is mapped from docs/public-*.md and the README draft. Text
rewrites from the previous manifest are carried forward when they still match.
Review the resulting diff before exporting.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PRODUCT_DIRS = ('app', 'scripts', 'tests', 'patches', 'config', 'licenses')
EXCLUDE = {
    'patches/README.md',                    # replaced by docs/public-patches.md
    'patches/dxmt-overwatch-smooth60.patch',  # historical snapshot, superseded
    # Developer record/replay and play-test tools stay in the engineering
    # archive; the shipped part of that DXMT branch is
    # patches/dxmt-v1-performance.patch.
    'patches/dxmt-replay-recorder.patch',
    'scripts/build_dxmt_replay.py', 'scripts/cpu_profile.py', 'scripts/gpu_trace.py',
    'scripts/playtest_report.py', 'scripts/record_session.py', 'scripts/recording_stats.py',
    'scripts/replay.py', 'scripts/window_snapshot.m',
}
DOCS = {
    'docs/public-readme.md': 'README.md',
    'docs/public-gitignore.md': '.gitignore',
    'docs/public-precommit.md': '.githooks/pre-commit',
    'docs/public-prepush.md': '.githooks/pre-push',
    'docs/public-notices.md': 'THIRD_PARTY_NOTICES.md',
    'docs/public-building.md': 'docs/BUILDING.md',
    'docs/public-development.md': 'docs/DEVELOPMENT.md',
    'docs/public-installation.md': 'docs/INSTALLATION.md',
    'docs/public-performance.md': 'docs/PERFORMANCE.md',
    'docs/public-sources.json': 'docs/SOURCES.json',
    'docs/public-support.md': 'docs/SUPPORT.md',
    'docs/public-patches.md': 'patches/README.md',
    # GitHub's own files: the Sponsor button and the issue forms.
    'docs/public-funding.md': '.github/FUNDING.yml',
    'docs/public-issue-bug.md': '.github/ISSUE_TEMPLATE/bug_report.yml',
    'docs/public-issue-performance.md': '.github/ISSUE_TEMPLATE/performance_report.yml',
    'docs/public-issue-idea.md': '.github/ISSUE_TEMPLATE/feature_request.yml',
    'docs/public-issue-config.md': '.github/ISSUE_TEMPLATE/config.yml',
    'docs/candidate-parity-contract.json': 'docs/candidate-parity-contract.json',
    'licenses/PROJECT-MIT': 'LICENSE',
    '.gitattributes': '.gitattributes',
}
EXECUTABLE_TARGETS = {'.githooks/pre-commit', '.githooks/pre-push'}
BINARY_SUFFIXES = {'.png', '.icns', '.jpg', '.jpeg'}
# The README draft links to staging paths; the public tree uses release paths.
README_REPLACEMENTS = [
    ('../app/Resources/AppIcon.png', 'app/Resources/AppIcon.png'),
    ('../app/Resources/Banner.png', 'app/Resources/Banner.png'),
    ('../app/Resources/AuthorPhoto.jpg', 'app/Resources/AuthorPhoto.jpg'),
    ('../app/Resources/ReadmeBenchmark.png', 'app/Resources/ReadmeBenchmark.png'),
    ('../app/Resources/AuthorPhotoRound.png', 'app/Resources/AuthorPhotoRound.png'),
    ('../app/Resources/ButtonCoffee.png', 'app/Resources/ButtonCoffee.png'),
    ('../app/Resources/ButtonMosaic.png', 'app/Resources/ButtonMosaic.png'),
    ('../app/Resources/ButtonLinkedIn.png', 'app/Resources/ButtonLinkedIn.png'),
    ('(public-performance.md)', '(docs/PERFORMANCE.md)'),
    ('(public-performance.md#', '(docs/PERFORMANCE.md#'),
    ('(public-installation.md)', '(docs/INSTALLATION.md)'),
    ('(../patches)', '(patches)'),
    ('(public-support.md)', '(docs/SUPPORT.md)'),
    ('(public-support.md#', '(docs/SUPPORT.md#'),
    ('(public-development.md)', '(docs/DEVELOPMENT.md)'),
    ('(public-building.md)', '(docs/BUILDING.md)'),
    ('(public-notices.md)', '(THIRD_PARTY_NOTICES.md)'),
    ('(../licenses/PROJECT-MIT)', '(LICENSE)'),
]


def tracked():
    out = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '--stage', '-z', *PRODUCT_DIRS])
    for record in out.decode().split('\0'):
        if record:
            meta, path = record.split('\t', 1)
            yield path, meta.split()[0] == '100755'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/public-export.json')
    parser.add_argument('--previous', type=Path, default=ROOT / 'docs/public-export.json')
    args = parser.parse_args()
    previous = {}
    if args.previous.exists():
        previous = {e['from']: e for e in json.loads(args.previous.read_text())['files']}
    entries = {}

    def add(source, target, executable=False):
        path = ROOT / source
        data = path.read_bytes()
        entry = {'from': source, 'to': target, 'sha256': hashlib.sha256(data).hexdigest(),
                 'executable': executable}
        if Path(target).suffix.lower() in BINARY_SUFFIXES:
            entry['binary'] = True
        else:
            text = data.decode('utf-8')
            kept = [r for r in previous.get(source, {}).get('replacements', [])
                    if text.count(r['find']) == r['count']]
            if source == 'docs/public-readme.md':
                kept = [{'find': f, 'replace': t, 'count': text.count(f)}
                        for f, t in README_REPLACEMENTS if text.count(f)]
                todo = [line for line in text.splitlines() if line.startswith('<!-- TODO')]
                kept += [{'find': line + '\n\n', 'replace': '', 'count': 1} for line in todo
                         if text.count(line + '\n\n') == 1]
            if kept:
                entry['replacements'] = kept
        entries[target] = entry

    for path, executable in tracked():
        if path in EXCLUDE or path in DOCS:
            continue
        add(path, path, executable)
    for source, target in DOCS.items():
        add(source, target, target in EXECUTABLE_TARGETS)
    manifest = {'schema_version': 2, 'purpose': 'reviewed public source export',
                'files': [entries[k] for k in sorted(entries)]}
    args.output.write_text(json.dumps(manifest, indent=2) + '\n')
    print('Manifest entries:', len(entries), '->', args.output)


if __name__ == '__main__':
    main()
