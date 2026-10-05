#!/usr/bin/env python3
"""Export an explicitly reviewed source allowlist into a local Git repository.

The manifest pins every input byte; output is validated before any file is
written. The default mode creates a new repository at an absent destination.
--refresh writes the reviewed tree into an existing clean public checkout as
one new commit, which is how later releases update the public repository.
No remote is added and nothing is pushed by this tool.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

from audit_public_source import inspect_bytes, inspect_path, is_image_asset

# Drafts mark numbers and media still to come with a bracketed TBD marker. A preview export may
# keep them (--allow-placeholders); a release export refuses them. The pattern is
# split so this file does not match itself.
PLACEHOLDER = re.compile(r'\[' + 'TBD' + r'\b')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def plan(source, manifest, forbidden=(), allow_placeholders=False):
    outputs = {}
    for entry in manifest['files']:
        name, target = entry['from'], entry['to']
        inspect_path(name)
        inspect_path(target)
        origin = source / name
        # resolve() catches symlinked parents as well as symlinked files.
        if origin.is_symlink() or origin.resolve() != source.resolve() / name:
            raise ValueError('Symlinked input is not permitted: ' + name)
        data = origin.read_bytes()
        if digest(data) != entry['sha256']:
            raise ValueError('Reviewed input changed: ' + name)
        if entry.get('binary'):
            # Reviewed image assets: hash-pinned, size-capped, never rewritten.
            if not is_image_asset(target, data) or entry.get('replacements'):
                raise ValueError('Binary export limited to reviewed image assets: ' + name)
        else:
            text = data.decode('utf-8')
            for replacement in entry.get('replacements', []):
                if text.count(replacement['find']) != replacement['count']:
                    raise ValueError('Replacement count differs: ' + name)
                text = text.replace(replacement['find'], replacement['replace'])
            if not allow_placeholders and PLACEHOLDER.search(text):
                raise ValueError('Unfilled TBD placeholder in ' + target)
            data = text.encode('utf-8')
            inspect_bytes(target, data, forbidden)
        if target.casefold() in {p.casefold() for p in outputs}:
            raise ValueError('Duplicate output: ' + target)
        outputs[target] = (data, entry.get('executable', False))
    if not {'README.md', 'LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md'} <= outputs.keys():
        raise ValueError('Required public documentation is missing')
    return outputs


def write_outputs(destination, outputs):
    for name, (data, executable) in outputs.items():
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755 if executable else 0o644)
    return {name: digest(data) for name, (data, _) in outputs.items()}


def export(source, manifest, destination, forbidden=(), allow_placeholders=False):
    if destination.exists() or destination.is_symlink():
        raise ValueError('Destination must not exist')
    outputs = plan(source, manifest, forbidden, allow_placeholders)
    destination.mkdir(parents=True)
    return write_outputs(destination, outputs)


def refresh(source, manifest, destination, forbidden=(), allow_placeholders=False):
    """Replace the tracked tree of an existing clean checkout with the reviewed outputs."""
    def git(*command):
        return subprocess.run(['git', '-C', str(destination), *command],
                              check=True, capture_output=True, text=True).stdout
    if not (destination / '.git').is_dir():
        raise ValueError('Refresh destination must be an existing Git checkout')
    if git('status', '--porcelain').strip():
        raise ValueError('Refresh destination has uncommitted changes')
    outputs = plan(source, manifest, forbidden, allow_placeholders)
    tracked = git('ls-files', '-z').split('\0')
    for name in tracked:
        if name:
            (destination / name).unlink()
    for parent in sorted({(destination / n).parent for n in tracked if n}, reverse=True):
        if parent != destination and parent.exists() and not any(parent.iterdir()):
            parent.rmdir()
    return write_outputs(destination, outputs)


def source_identity(source):
    def config(key):
        result = subprocess.run(['git', '-C', str(source), 'config', key],
                                capture_output=True, text=True)
        return result.stdout.strip()
    return config('user.name'), config('user.email')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--refresh', action='store_true',
                        help='write into an existing clean public checkout as a new commit')
    parser.add_argument('--message', default='Publish Recall source')
    parser.add_argument('--allow-placeholders', action='store_true',
                        help='preview exports only: keep TBD markers, which a release refuses')
    parser.add_argument('--author-name', help='defaults to the source checkout git user.name')
    parser.add_argument('--author-email', help='defaults to the source checkout git user.email')
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    manifest = json.loads(args.manifest.read_text())
    emails = subprocess.check_output(
        ['git', '-C', str(source), 'log', '--all', '--format=%ae%n%ce'],
        text=True).splitlines()
    # Author names are public by the owner's decision; local account name,
    # commit e-mail addresses and the private README banner are not.
    banner = ' '.join(['Private,', 'independent', 'development', 'repository'])
    forbidden = [Path.home().name, banner, *set(emails)]
    if args.check:
        outputs = plan(source, manifest, forbidden, args.allow_placeholders)
        print('Reviewed source plan passed:', len(outputs), 'files')
        return
    name, email = source_identity(source)
    name, email = args.author_name or name, args.author_email or email
    if not name or not email:
        raise SystemExit('Set --author-name and --author-email or configure git user.name/user.email')

    def git(*command):
        return subprocess.run(['git', '-C', str(args.destination), *command],
                              check=True, capture_output=True, text=True)
    if args.refresh:
        hashes = refresh(source, manifest, args.destination, forbidden, args.allow_placeholders)
    else:
        hashes = export(source, manifest, args.destination, forbidden, args.allow_placeholders)
        git('init', '-b', 'main')
        git('config', 'commit.gpgsign', 'false')
        git('config', 'core.hooksPath', '.githooks')
    git('config', 'user.name', name)
    git('config', 'user.email', email)
    git('add', '--all')
    if git('status', '--porcelain').stdout.strip():
        git('commit', '-m', args.message)
    else:
        print('No changes against the existing public tree')
    if not args.refresh and git('remote').stdout.strip():
        raise RuntimeError('Unexpected remote on local source preview')
    commits = int(git('rev-list', '--count', 'HEAD').stdout.strip())
    report = {'status': 'local_source_export', 'files': hashes,
              'commit': git('rev-parse', 'HEAD').stdout.strip(),
              'remotes': git('remote').stdout.split(), 'commits': commits}
    # Keep private source mapping and audit reports outside the public Git tree.
    args.destination.with_suffix('.export.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Exported public source:', len(hashes), 'files;', report['commit'])


if __name__ == '__main__':
    main()
