#!/usr/bin/env python3
"""Audit source paths and all reachable Git blob/message content without values.

This is a source/metadata check, not proof of arbitrary text being secret-free.
Binary release assets require a separate distribution audit.
"""
import argparse
from pathlib import PurePosixPath
import re
import subprocess


DENIED = {'runtime', 'logs', 'downloads', 'prefixes', '.git', '__pycache__'}
PATTERNS = [
    ('private key', rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'),
    ('GitHub credential', rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b'),
    ('AWS access key', rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    ('Slack credential', rb'\bxox[baprs]-[A-Za-z0-9-]{20,}\b'),
    # Placeholder accounts used by CI recipes and test fixtures are permitted.
    ('macOS account path', rb'/Users/(?!runner/|example/)[A-Za-z0-9_.-]+/'),
]


def inspect_path(name):
    path = PurePosixPath(name)
    if (not name or '\\' in name or path.is_absolute() or str(path) != name
            or any(p in DENIED or p in ('.', '..') for p in path.parts)
            or any(p == '.env' or p.startswith('.env.') for p in path.parts)
            or any(p.lower().endswith(('.app', '.dmg', '.dll', '.exe', '.dylib', '.so',
                                      '.p8', '.p12', '.pem', '.key', '.zip', '.xz', '.gz',
                                      '.csv', '.jsonl'))
                   for p in path.parts)):
        raise ValueError('Excluded/unsafe source path: ' + name)


IMAGE_SUFFIXES = ('.png', '.icns', '.jpg', '.jpeg')
IMAGE_LIMIT = 4 * 1024 * 1024


def is_image_asset(name, data):
    """Reviewed artwork under app/Resources is the only binary content allowed."""
    return (name.startswith('app/Resources/') and name.lower().endswith(IMAGE_SUFFIXES)
            and len(data) <= IMAGE_LIMIT)


def inspect_bytes(name, data, forbidden=()):
    if len(data) > 2 * 1024 * 1024 or b'\0' in data:
        raise ValueError('Binary or oversized source payload: ' + name)
    text = data.decode('utf-8')
    for label, pattern in PATTERNS:
        if re.search(pattern, data):
            raise ValueError(label + ' in ' + name)
    for token in forbidden:
        if token and len(token) >= 4 and token.casefold() in text.casefold():
            raise ValueError('Private audit token in ' + name)


def audit_git(root, staged=False, forbidden=()):
    def git(*args):
        return subprocess.check_output(['git', '-C', str(root), *args])
    seen = set()
    if staged:
        trees = [None]
    else:
        trees = git('rev-list', '--all').decode().splitlines()
        for commit in trees:
            inspect_bytes('commit metadata', git('show', '-s', '--format=fuller', commit), forbidden)
        for ref in git('for-each-ref', '--format=%(refname)').decode().splitlines():
            inspect_bytes('ref name', ref.encode(), forbidden)
            oid = git('rev-parse', ref).decode().strip()
            if git('cat-file', '-t', oid).strip() == b'tag':
                inspect_bytes('tag metadata', git('cat-file', 'tag', oid), forbidden)
            # A ref can point directly to a tree/blob, outside commit ancestry.
            peeled = git('rev-parse', ref + '^{}').decode().strip()
            kind = git('cat-file', '-t', peeled).strip()
            if kind == b'tree':
                trees.append(peeled)
            elif kind == b'blob':
                inspect_bytes('direct blob ref', git('cat-file', 'blob', peeled), forbidden)
    for tree in trees:
        listing = git('ls-tree', '-rz', tree) if tree else git('ls-files', '--stage', '-z')
        for record in listing.split(b'\0'):
            if not record:
                continue
            meta, path = record.split(b'\t', 1)
            fields = meta.decode().split()
            mode, oid = (fields[0], fields[2]) if tree else (fields[0], fields[1])
            name = path.decode()
            inspect_path(name)
            if mode not in ('100644', '100755'):
                raise ValueError('Symlink/submodule is not permitted: ' + name)
            if not tree and fields[2] != '0':
                raise ValueError('Unresolved index: ' + name)
            if oid not in seen:
                blob = git('cat-file', 'blob', oid)
                if not is_image_asset(name, blob):
                    inspect_bytes(name, blob, forbidden)
                seen.add(oid)
    return len(seen)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default='.')
    parser.add_argument('--staged', action='store_true')
    args = parser.parse_args()
    print('Source audit passed:', audit_git(args.root, args.staged), 'unique blobs')


if __name__ == '__main__':
    main()
