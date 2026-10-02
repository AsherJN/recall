#!/usr/bin/env python3
"""Exercise actual native telemetry with fake Metal callbacks, never a game/window."""
import argparse
import csv
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--arch", choices=("arm64", "x86_64"), default="arm64")
parser.add_argument("--mode", action="append", choices=("disabled", "normal", "missing", "capped", "concurrent", "overflow", "pending", "blocked_shutdown", "pre_shutdown", "init_race", "rotation"))
parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2] / "runtime/source/dxmt-ow2")
args = parser.parse_args()
directory = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="native-display-", dir=directory) as temporary:
    output = Path(temporary)
    library, harness = output / "display_log.dylib", output / "harness"
    common = ["/usr/bin/clang", "-arch", args.arch, "-x", "objective-c", "-fblocks", "-Wall", "-Wextra", "-Werror",
              "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-framework", "Foundation",
              "-framework", "Metal", "-framework", "QuartzCore"]
    if args.mode == ["rotation"]:
        common += ["-DDXMT_DISPLAY_SEGMENT_BYTES=65536", "-DDXMT_DISPLAY_HITCH_BYTES=1024"]
    subprocess.run(common + ["-dynamiclib", str(args.source / "src/winemetal/unix/display_log.c"), "-o", str(library)], check=True)
    subprocess.run(common + [str(directory / "harness.m"), "-o", str(harness)], check=True)
    for mode in args.mode or ("disabled", "normal", "missing", "capped", "concurrent", "overflow", "pending", "blocked_shutdown", "pre_shutdown", "init_race"):
        prefix = output / mode
        result = subprocess.run([str(harness), str(library), str(prefix), mode], capture_output=True, text=True, timeout=15)
        if result.returncode:
            print(result.stdout, result.stderr)
            raise SystemExit(result.returncode)
        report = json.loads(result.stdout)
        path = Path(f"{prefix}-{report['pid']}{'.capture' if report['fifo'] else ''}.csv")
        if mode in ("disabled", "pre_shutdown"):
            assert not path.exists(), "disabled instrumentation wrote a file"
            print(f"PASS {args.arch}: {mode} creates no logs/tokens")
            continue
        rows = list(csv.DictReader(path.open()))
        if mode == "rotation":
            lifetime = json.loads(path.with_suffix(".summary.json").read_text())
            assert lifetime["rotations"] > 3, lifetime
            assert lifetime["valid_presentations"] >= 1950, lifetime
            assert lifetime["adjacent_intervals"] >= 1900, lifetime
            assert lifetime["over50ms"] >= 15, lifetime
            assert lifetime["io_errors"] == lifetime["dropped_requests"] == 0, lifetime
            assert max(int(r["sequence"]) for r in rows) == 2000
            for suffix in (".csv", ".1.csv", ".2.csv"):
                assert path.with_suffix(suffix).stat().st_size <= 66048
            assert len(rows) < lifetime["requests_observed"]
            print(f"PASS {args.arch}: rotation persists recent events and lifetime summary; {lifetime}")
            continue
        summary = rows[-1]
        assert summary["event"] == "summary", "missing graceful tail summary"
        if mode == "overflow":
            assert int(summary["dropped_events"]) > 0, "forced stalled writer should overflow bounded ring"
        elif mode == "pending":
            assert int(summary["active_traces"]) == 8, "shutdown must disclose pending callbacks"
        elif mode == "concurrent":
            assert int(summary["active_traces"]) == 0, "concurrent callbacks must retire all traces"
            assert all(None not in row for row in rows), "concurrent writers corrupted CSV records"
        else:
            assert int(summary["dropped_events"]) == 0, "unexpected event loss"
            assert int(summary["active_traces"]) == 0, "expected all callbacks/tokens retired"
        if mode == "capped":
            assert int(summary["dropped_requests"]) == 88, "active trace limit should cap 600 requests at512"
        if mode in ("normal", "missing", "capped"):
            requests = [r for r in rows if r["event"] == "request"]
            retired = [r for r in rows if r["event"] == "retired"]
            assert len(requests) == len(retired) == report["traces"]
            assert all(float(r["presented_s"]) == 0 and r["presented_state"] == "pending" for r in requests)
            if mode == "missing":
                assert {int(r["callbacks_seen"]) for r in retired} == {0, 1, 2, 3}
            else:
                assert all(r["callbacks_seen"] == "3" for r in retired)
                presented = [r for r in rows if r["event"] == "presented"]
                completed = [r for r in rows if r["event"] == "gpu_complete"]
                assert len(presented) == len(completed) == report["traces"]
                assert presented[0]["presented_state"] == "zero_or_unavailable"
                assert any(r["gpu_state"] == "zero_or_unavailable" for r in completed)
                assert any(r["command_status"] == "5" and r["error_code"] == "42" for r in completed)
                for row in completed:
                    if row["gpu_state"] == "valid":
                        assert abs(float(row["gpu_end_s"]) - float(row["gpu_start_s"]) - .003) < 1e-8
        print(f"PASS {args.arch}: {mode}; rows={len(rows)}, traces={report['traces']}, shutdown={report['shutdown_seconds']}s")
