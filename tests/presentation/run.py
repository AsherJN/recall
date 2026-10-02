#!/usr/bin/env python3
"""Actual queue/logger code: asynchronous schema, rotation, concurrent overflow, failure, shutdown."""
import argparse
import csv
import json
from pathlib import Path
import subprocess
import tempfile


def body(source, signature):
    start = source.index("{", source.index(signature))
    depth, end = 1, start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]

parser = argparse.ArgumentParser()
parser.add_argument("--arch", choices=("arm64", "x86_64"), default="arm64")
parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2] / "runtime/source/dxmt-ow2")
args = parser.parse_args()
test_dir = Path(__file__).resolve().parent
header = (args.source / "src/dxmt/dxmt_command_queue.hpp").read_text()
implementation = (args.source / "src/dxmt/dxmt_command_queue.cpp").read_text()
harness = (test_dir / "harness.cpp.in").read_text()
harness = harness.replace("@FRAME_LOG_TICK@", body(header, "FrameLogTick(int64_t"))
harness = harness.replace("@QUEUE_DESTRUCTOR@", body(implementation, "CommandQueue::~CommandQueue()"))
with tempfile.TemporaryDirectory(prefix="frame-log-", dir=test_dir) as temporary:
    directory = Path(temporary)
    # Platform thread adapter only; all logger methods and actual queue bodies are unchanged.
    (directory / "thread.hpp").write_text('#pragma once\n#include <thread>\nnamespace dxmt { using thread = std::thread; namespace this_thread { inline bool isInModuleDetachment() { return false; } } }\n')
    (directory / "dxmt_frame_log.hpp").write_text((args.source / "src/dxmt/dxmt_frame_log.hpp").read_text())
    cpp, exe = directory / "harness.cpp", directory / "harness"
    cpp.write_text(harness)
    subprocess.run(["/usr/bin/clang++", "-arch", args.arch, "-std=c++20", "-Wall", "-Wextra", "-Werror",
                    "-DDXMT_FRAME_SEGMENT_BYTES=4096", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    str(cpp), "-o", str(exe)], check=True)
    for mode in ("disabled", "normal", "rotation", "overflow", "missing", "blocked"):
        prefix = directory / mode
        if mode == "missing": prefix = prefix / "absent" / "frames"
        result = subprocess.run([str(exe), str(prefix), mode], capture_output=True, text=True, timeout=15)
        if result.returncode: print(result.stdout, result.stderr); raise SystemExit(result.returncode)
        if mode in ("disabled", "missing"): print(f"PASS: {mode}"); continue
        pid = int(result.stdout.strip()); base = Path(f"{prefix}-{pid}")
        summary = json.loads(Path(f"{base}.summary.json").read_text())
        assert summary["io_errors"] == summary["disk_events_lost"] == 0, summary
        if mode == "rotation":
            assert summary["frame_rotations"] > 3 and summary["event_rotations"] > 3, summary
            assert summary["boundary_intervals"] > 2900, summary
            assert summary["span_counts"][4] > 2900, summary
            for part in [base.with_suffix(".csv"), Path(f"{base}.1.csv"), Path(f"{base}.2.csv"), Path(f"{base}.events.csv")]:
                assert part.stat().st_size <= 4400
                rows = list(csv.DictReader(part.open())); assert rows and all(None not in row for row in rows)
            assert len(list(csv.DictReader(Path(f"{base}.csv").open()))) < summary["boundary_intervals"]
        if mode == "overflow": assert summary["dropped_events"] > 0, summary
        print(f"PASS: {mode}; summary={summary}")
