#!/usr/bin/env python3
"""Prepare expensive saved Metal pipelines on a cloned cache before game launch.

The helper uses the production codec/manager in standalone-only preparation mode.
Original data remains available until a fresh-process strict archive verification
passes. No game files or global graphics caches are changed.
"""
import argparse
import ctypes
import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
NATIVE = ROOT / 'runtime/source/dxmt-ow2/src/winemetal/unix'
HELPER = ROOT / 'runtime/build/pipeline-prepare'
CACHE = ROOT / 'runtime/dxmt-pipeline-cache-source'
NAMESPACE = 'ow2-source-v1'
MIN_COST_US = 16667
ARCHIVE_TARGET_BYTES = int(128 * 2**20 * .90)
ARCHIVE_STOP_BYTES = int(128 * 2**20 * .85)  # Avoid recompaction/backup growth for tiny additions.
MAX_PREPARED_KEYS = 7168  # Both schema-2 key arrays must fit the native 1 MiB manifest bound.
SOURCES = ('pipeline_cache.c', 'pipeline_cache.h', 'pipeline_recipe.c', 'pipeline_recipe.h')


class PipelinePreparationUnsafeError(RuntimeError):
    """Launch must stop because publication or another preparation is in progress."""


def exchange_directories(left, right):
    """Atomically exchange two local cache directories, with no missing-path gap."""
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    exchange = libc.renameatx_np
    exchange.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    exchange.restype = ctypes.c_int
    # Local SDK: AT_FDCWD=-2; RENAME_SWAP=0x00000002 (macOS 10.12+).
    if exchange(-2, os.fsencode(left), -2, os.fsencode(right), 2):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes():
    return {name: sha(NATIVE / name) for name in SOURCES} | {'pipeline_prepare.m': sha(ROOT / 'scripts/pipeline_prepare.m')}


def build_helper():
    HELPER.mkdir(parents=True, exist_ok=True)
    library = HELPER / 'libpipeline_prepare.dylib'
    commands = [
        ['/usr/bin/clang', '-arch', 'x86_64', '-x', 'objective-c', '-fblocks', '-fno-objc-arc',
         '-DDXMT_PIPELINE_CACHE_OFFLINE_TOOL', '-O2', '-dynamiclib',
         str(NATIVE / 'pipeline_recipe.c'), str(NATIVE / 'pipeline_cache.c'),
         '-framework', 'Foundation', '-framework', 'Metal', '-framework', 'QuartzCore',
         '-install_name', str(library), '-o', str(library)],
        ['/usr/bin/clang', '-arch', 'x86_64', '-x', 'objective-c', '-fblocks', '-fobjc-arc',
         '-DDXMT_PIPELINE_CACHE_OFFLINE_TOOL', '-O2', '-I', str(NATIVE),
         '-c', str(ROOT / 'scripts/pipeline_prepare.m'), '-o', str(HELPER / 'main.o')],
        ['/usr/bin/clang', '-arch', 'x86_64', str(HELPER / 'main.o'), str(library),
         '-framework', 'Foundation', '-framework', 'Metal', '-o', str(HELPER / 'prepare')],
    ]
    before = source_hashes()
    with (HELPER / 'build.log').open('w') as log:
        for command in commands:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    if before != source_hashes():
        raise RuntimeError('Preparation source changed during build')
    manifest = {'sources': before, 'files': {name: sha(HELPER / name) for name in ('prepare', library.name)}}
    (HELPER / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def game_running():
    rows = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
    return any(row.rstrip().endswith('Overwatch.exe') for row in rows)


def validate_helper():
    manifest = json.loads((HELPER / 'manifest.json').read_text())
    if manifest['sources'] != source_hashes():
        raise RuntimeError('Preparation helper does not match current source')
    if any(sha(HELPER / name) != value for name, value in manifest['files'].items()):
        raise RuntimeError('Preparation helper binary hash mismatch')


def archive_keys(directory):
    path = directory / 'archive.json'
    if not path.exists():
        return set()
    manifest = json.loads(path.read_text())
    keys = set(manifest.get('prepared_keys', []))
    if len(keys) > 32768 or any(len(k) != 64 or any(c not in '0123456789abcdef' for c in k) for k in keys):
        raise RuntimeError('Invalid archive key catalog')
    return keys


def candidate_count(directory, previous):
    count = 0
    for path in (directory / 'recipes').glob('*.json'):
        if path.stem in previous:
            continue
        try:
            cost = json.loads(path.read_text()).get('cost_us', 0)
            count += isinstance(cost, (int, float)) and MIN_COST_US <= cost <= 60000000
        except (OSError, ValueError, TypeError):
            continue  # The production decoder handles corruption in the clone.
    return count


def preparation_limit(directory, previous, candidates):
    """Estimate a conservative batch from the current archive's measured size."""
    path = directory / 'archive.json'
    manifest = json.loads(path.read_text()) if path.exists() else {}
    archive_bytes = sum(entry['bytes'] for entry in manifest.get('archives', []))
    if archive_bytes >= ARCHIVE_STOP_BYTES:
        return len(previous)
    additional = 256
    if previous and archive_bytes > 0:
        additional = max(1, int(len(previous) * (ARCHIVE_TARGET_BYTES / archive_bytes - 1)))
    return min(MAX_PREPARED_KEYS, len(previous) + min(candidates, additional, 1024))


def refresh_inventory(directory, previous):
    """Bounded historical-cost ranking, not a prediction of next-match frequency.

    Metadata is read only. Complete recipe/dependency validity is checked by the
    native decoder and fresh-process replay before a replacement can publish.
    """
    costs, modified = {}, {}
    for path in sorted((directory / 'recipes').glob('*.json'))[:32768]:
        if path.is_symlink() or path.stat().st_size > 2 * 1024 * 1024:
            continue
        try:
            cost = json.loads(path.read_text()).get('cost_us', 0)
            if (len(path.stem) == 64 and all(c in '0123456789abcdef' for c in path.stem)
                    and type(cost) in (int, float) and math.isfinite(cost) and 0 <= cost <= 60000000):
                costs[path.stem] = cost
                modified[path.stem] = int(path.stat().st_mtime)
        except (OSError, ValueError, TypeError):
            continue
    newest = max(modified.values(), default=0)
    # Persisted recipe modification is evidence of a successfully recorded use,
    # not a frequency counter. Prefer recent uses with a six-hour half-life,
    # retaining a 25% floor for older expensive combinations.
    scores = {key: min(cost, 250000) * (.25 + .75 * 2 ** (-(newest-modified[key])/21600))
              for key, cost in costs.items()}
    ranking = sorted((key for key, cost in costs.items() if cost >= MIN_COST_US),
                     key=lambda key: (-scores[key], key))
    # The native tool uses the same descending cost order. Score saturation
    # prevents one historical multi-second outlier justifying a poor replacement.
    score = lambda keys: sum(scores.get(key, 0) for key in keys)
    fingerprint = hashlib.sha256(json.dumps(sorted((k,c,modified[k]) for k,c in costs.items()), separators=(',', ':')).encode()).hexdigest()
    limit = min(MAX_PREPARED_KEYS, max(1, len(previous)), len(ranking))
    proposed = set(ranking[:limit])
    return dict(costs=costs, scores=scores, ranking=ranking, fingerprint=fingerprint, limit=limit,
                previous_score=score(previous), proposed_score=score(proposed),
                new_keys=len(proposed - previous))


def selection_score(keys, inventory):
    return sum(inventory['scores'].get(key, 0) for key in keys)


def reset_cloned_archive(directory):
    """Discard only reproducible archive output in the unpublished clone."""
    (directory / 'archive.json').unlink(missing_ok=True)
    for path in (directory / 'archives').glob('*.metallib'):
        if path.is_symlink():
            raise RuntimeError('Refusing symlink in cloned archive directory')
        path.unlink()


def run_helper(cache, output, mode, namespace=NAMESPACE, limit=4096, budget=180000, selection=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith(('DXMT_', 'MTL_'))}
    env.update(DXMT_PIPELINE_CACHE_PATH=str(cache), DXMT_PIPELINE_CACHE_NAMESPACE=namespace,
               DXMT_PIPELINE_CACHE_LOG=str(output / mode),
               DXMT_PIPELINE_CACHE_PREWARM_LIMIT=str(limit), DXMT_PIPELINE_CACHE_PREWARM_MS=str(budget),
               DXMT_PIPELINE_CACHE_MIN_COST_US=str(MIN_COST_US),
               DXMT_PIPELINE_CACHE_VERIFY_ONLY='1' if mode == 'verify' else '0')
    if selection is not None:
        selection_path = output / 'selected-recipes.json'
        selection_path.write_text(json.dumps(selection) + '\n')
        env['DXMT_PIPELINE_CACHE_SELECTION'] = str(selection_path)
    with (output / f'{mode}.stderr.log').open('w') as log:
        result = subprocess.run([str(HELPER / 'prepare')], env=env, stdout=subprocess.PIPE,
                                stderr=log, text=True, timeout=budget / 1000 + 90)
    result.check_returncode()
    data = json.loads(result.stdout)
    (output / f'{mode}.result.json').write_text(json.dumps(data, indent=2) + '\n')
    return data


def prepare_before_launch():
    if game_running():
        raise PipelinePreparationUnsafeError('Close Overwatch before preparing pipelines')
    if not CACHE.is_dir():
        return {'status': 'skipped', 'reason': 'No learned pipeline cache yet'}
    validate_helper()
    namespaces = [p for p in CACHE.iterdir() if p.is_dir() and (p / 'recipes').is_dir()]
    if len(namespaces) != 1:
        return {'status': 'skipped', 'reason': 'Expected one existing device namespace'}
    original = namespaces[0]
    previous = archive_keys(original)
    candidates = candidate_count(original, previous)
    if not candidates:
        return {'status': 'up_to_date', 'prepared_keys': len(previous), 'new_expensive_candidates': 0}
    limit = preparation_limit(original, previous, candidates)
    refresh = limit <= len(previous)
    inventory = refresh_inventory(original, previous) if refresh else None
    decision_path = original / 'refresh-decision.json'
    if refresh:
        archive_hash = sha(original / 'archive.json')
        decision_key = dict(schema=2, fingerprint=inventory['fingerprint'], archive_sha256=archive_hash)
        try:
            prior_decision = json.loads(decision_path.read_text())
        except (OSError, ValueError):
            prior_decision = {}
        if all(prior_decision.get(k) == v for k, v in decision_key.items()):
            return {'status': 'up_to_date', 'reason': 'Same bounded refresh was already evaluated',
                    'prepared_keys': len(previous)}
        limit = inventory['limit']
        if not inventory['new_keys'] or inventory['proposed_score'] <= inventory['previous_score'] * 1.05:
            return {'status': 'up_to_date', 'reason': 'Existing archive already covers comparable historical cost',
                    'prepared_keys': len(previous), 'refresh_score': inventory['proposed_score']}
    if limit <= len(previous):
        if not refresh or not limit:
            return {'status': 'skipped', 'reason': 'No bounded preparation candidates',
                    'prepared_keys': len(previous), 'new_expensive_candidates': candidates}
    if shutil.disk_usage(ROOT).free < 2 * 2**30:
        return {'status': 'skipped', 'reason': 'Preparation preserves at least 2 GiB disk headroom'}
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    output = ROOT / 'logs/dxmt' / f'offline-preparation-{stamp}'
    output.mkdir(parents=True)
    began = time.monotonic()
    result = {'status': 'started', 'artifact': str(output), 'previous_prepared': len(previous),
              'new_expensive_candidates': candidates, 'policy': 'refresh' if refresh else 'expand', 'attempts': []}
    if refresh:
        result['previous_cost_score_us'] = inventory['previous_score']
    lease_path = ROOT / 'runtime/.pipeline-preparation.lock'
    with lease_path.open('a') as lease, (original / 'write.lock').open('a') as writer_lease:
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(writer_lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise PipelinePreparationUnsafeError('Another game or preparation owns the pipeline cache') from exc
        if game_running():
            raise PipelinePreparationUnsafeError('Overwatch started during preparation setup')
        temp = tempfile.mkdtemp(prefix='pipeline-prepare-', dir=ROOT / 'runtime/build')
        cleanup_safe = True
        try:
            cloned = Path(temp) / 'cache'
            candidate = cloned / original.name
            baseline = {str(p.relative_to(original)): sha(p) for group in ('recipes', 'libraries')
                        for p in (original / group).iterdir() if p.is_file() and not p.is_symlink()}
            for attempt in range(3):
                if cloned.exists():
                    shutil.rmtree(cloned)
                subprocess.run(['/bin/cp', '-cR', str(CACHE), str(cloned)], check=True)
                if refresh:
                    reset_cloned_archive(candidate)
                attempt_output = output / f'attempt-{attempt + 1}'
                attempt_output.mkdir()
                prepare_options = dict(limit=limit)
                if refresh:
                    prepare_options['selection'] = inventory['ranking'][:limit]
                prepared = run_helper(cloned, attempt_output, 'prepare', **prepare_options)
                if Path(prepared['namespace_directory']) != candidate or not prepared['write_owner']:
                    raise RuntimeError('Device namespace or writer ownership changed during preparation')
                selected = archive_keys(candidate)
                if len(selected) > limit or prepared['prepared'] != len(selected):
                    raise RuntimeError('Preparation exceeded or misreported its bounded selection')
                if refresh and not selected.issubset(set(inventory['ranking'][:limit])):
                    raise RuntimeError('Preparation included an unrequested refresh recipe')
                result['attempts'].append({'limit': limit, 'prepared': prepared['prepared'],
                                           'archive_failures': prepared['archive_failures']})
                score = selection_score(selected, inventory) if refresh else 0
                complete = (bool(selected - previous) and score > inventory['previous_score'] * 1.05
                            if refresh else previous.issubset(selected) and bool(selected - previous))
                if complete and not prepared['archive_failures']:
                    break
                additional = limit if refresh else limit - len(previous)
                if not prepared['archive_failures'] or additional <= 1:
                    break
                # Retry a smaller batch from the original cache, never a failed candidate.
                limit = (0 if refresh else len(previous)) + max(1, additional // 2)
            if not complete or prepared['archive_failures']:
                result.update(status='skipped', reason='No verified improvement within the archive budget')
            else:
                verified = run_helper(cloned, output, 'verify', limit=max(4096, len(selected)))
                if (not verified['write_owner'] or verified['failures'] or verified['archive_failures']
                        or verified['prepared'] != len(selected) or not verified['verify_only']):
                    raise RuntimeError('Fresh-process strict archive verification failed')
                for relative, digest in baseline.items():
                    if sha(candidate / relative) != digest:
                        raise RuntimeError('Preparation changed a learned recipe or AIR library')
                manifest = json.loads((candidate / 'archive.json').read_text())
                retained = {entry['sha256'] + '.metallib' for entry in manifest['archives']}
                for name in retained:
                    if sha(candidate / 'archives' / name) != Path(name).stem:
                        raise RuntimeError('Compiled archive content hash mismatch')
                # Prune only unused generated archives in the verified clone.
                # The entire previous active namespace becomes the rollback.
                for path in (candidate / 'archives').glob('*.metallib'):
                    if path.name not in retained:
                        path.unlink()
                if game_running():
                    raise PipelinePreparationUnsafeError('Overwatch started; prepared cache was not published')
                backup = ROOT / 'runtime/build-history' / f'cache-before-preparation-{stamp}'
                backup.mkdir()
                old = backup / original.name
                publication = {'active': str(original), 'candidate': str(candidate),
                               'backup': str(old), 'phase': 'verified_before_exchange'}
                (output / 'publication.json').write_text(json.dumps(publication, indent=2) + '\n')
                # Both names remain valid even if the process is killed during publication.
                cleanup_safe = False  # An interruption after the syscall must retain both directories.
                try:
                    exchange_directories(original, candidate)
                except OSError:
                    cleanup_safe = True  # A failed atomic syscall leaves both names unchanged.
                    raise
                except BaseException as exc:
                    raise PipelinePreparationUnsafeError(
                        f'Cache exchange interrupted; inspect preserved paths: {original}, {candidate}'
                    ) from exc
                try:
                    os.rename(candidate, old)
                except BaseException as exc:
                    try:
                        exchange_directories(original, candidate)
                        cleanup_safe = True
                    except BaseException as recovery:
                        cleanup_safe = False  # Preserve the old cache for manual recovery.
                        raise PipelinePreparationUnsafeError(
                            f'Cache publication needs review; both caches preserved: {original}, {candidate}'
                        ) from recovery
                    raise RuntimeError('Publication failed; original cache restored') from exc
                cleanup_safe = True
                publication['phase'] = 'published_with_backup'
                (output / 'publication.json').write_text(json.dumps(publication, indent=2) + '\n')
                result.update(status='prepared', prepared_keys=len(selected), added_keys=len(selected - previous),
                              retired_prepared_keys=len(previous - selected),
                              verified_keys=verified['prepared'], backup=str(backup), archive_bytes=verified['archive_bytes'])
                if refresh:
                    result['selected_cost_score_us'] = score
            if refresh:
                # A failed sizing/coverage attempt is not repeated every launch.
                # New learning or a different active archive permits reevaluation.
                decision_key['archive_sha256'] = sha(original / 'archive.json')
                temporary_decision = original / 'refresh-decision.tmp'
                temporary_decision.write_text(json.dumps(dict(decision_key, status=result['status'])) + '\n')
                os.replace(temporary_decision, decision_path)
        finally:
            if cleanup_safe:
                shutil.rmtree(temp)
    result['elapsed_s'] = round(time.monotonic() - began, 3)
    (output / 'report.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-helper', action='store_true')
    parser.add_argument('--prepare', action='store_true')
    args = parser.parse_args()
    if args.build_helper:
        print(json.dumps(build_helper(), indent=2))
    if args.prepare:
        print(json.dumps(prepare_before_launch(), indent=2))
    if not args.build_helper and not args.prepare:
        parser.error('Choose --build-helper and/or --prepare')


if __name__ == '__main__':
    main()
