#!/usr/bin/env python3
"""Build a standalone cache.c harness; never build or replace game libraries."""
from pathlib import Path
import os
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "runtime" / "diagnostics"
WORK.mkdir(parents=True, exist_ok=True)
SOURCE = ROOT / "tests" / "cache_writer" / "cache_writer_test.m"


def check(architecture: str, sanitize: bool, parent: Path) -> None:
    directory = parent / architecture
    directory.mkdir()
    binary = directory / "cache_writer_test"
    command = [
        "clang", "-arch", architecture, "-x", "objective-c", "-fblocks",
        "-fno-objc-arc", "-g", "-O1", "-Wall", "-Wextra", "-Werror",
        str(SOURCE), "-framework", "Foundation", "-lsqlite3", "-o", str(binary),
    ]
    if sanitize:
        command += ["-fsanitize=address,undefined"]
    subprocess.run(command, cwd=ROOT, check=True, timeout=60)
    environment = os.environ.copy()
    if sanitize:
        # LeakSanitizer is not available on macOS; ASan and UBSan remain active.
        environment["ASAN_OPTIONS"] = "detect_leaks=0:halt_on_error=1"
        environment["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
    normal = directory / "normal"
    normal.mkdir()
    print(f"=== {architecture}: actual cache.c, sanitizers={sanitize} ===", flush=True)
    subprocess.run([str(binary), str(normal)], env=environment, check=True, timeout=30)
    abrupt = directory / "abrupt"
    abrupt.mkdir()
    subprocess.run([str(binary), str(abrupt), "abrupt-exit"], env=environment, check=True, timeout=30)
    with sqlite3.connect(f"file:{abrupt / 'cache.db'}?mode=ro", uri=True) as connection:
        assert connection.execute("PRAGMA quick_check").fetchall() == [("ok",)]
        count = connection.execute("SELECT COUNT(*) FROM cache_24").fetchone()[0]
        assert 1000 - 31 <= count <= 1000, count
    print(f"PASS abrupt process exit: database intact, {count}/1000 entries recovered", flush=True)

    library = directory / "cache_writer.dylib"
    loader = directory / "unload_test"
    common = ["clang", "-arch", architecture, "-g", "-O1", "-Wall", "-Wextra", "-Werror"]
    if sanitize:
        common += ["-fsanitize=address,undefined"]
    subprocess.run(common + [
        "-x", "objective-c", "-fblocks", "-fno-objc-arc", "-dynamiclib",
        str(SOURCE.with_name("unload_test_library.m")), "-framework", "Foundation",
        "-lsqlite3", "-o", str(library),
    ], check=True, timeout=60)
    subprocess.run(common + [
        str(SOURCE.with_name("unload_test_main.c")), "-lsqlite3", "-o", str(loader),
    ], check=True, timeout=60)
    subprocess.run([str(loader), str(library), str(directory / "unload.db")],
                   env=environment, check=True, timeout=30)


with tempfile.TemporaryDirectory(prefix="cache-writer-tests-", dir=WORK) as temporary:
    check("arm64", True, Path(temporary))
    check("x86_64", False, Path(temporary))
