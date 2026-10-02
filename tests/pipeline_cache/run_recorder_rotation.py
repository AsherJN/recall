#!/usr/bin/env python3
"""Force production JSONL rotation using an existing exact-source recorder proof."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--proof", type=Path, required=True)
    args = parser.parse_args()
    proof = args.proof.resolve()
    original = json.loads((proof / "report.json").read_text())
    native = ROOT / "runtime/source/dxmt-ow2/src/winemetal/unix"
    before = {name: digest(native / name) for name in original["production_source_sha256"]}
    assert before == original["production_source_sha256"], "Existing proof does not match final source"
    assert not original["source_changed_during_run"], "Existing proof changed source during its run"
    nonce = re.search(r"vertex_([0-9a-f]+)", (proof / "fixture.metal").read_text())[1]
    output = ROOT / "logs/dxmt" / ("recorder-rotation-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
    output.mkdir()
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("DXMT_", "MTL_", "DYLD_"))}
    env.update(DXMT_PIPELINE_CACHE_PATH=str(output / "cache"),
               DXMT_PIPELINE_CACHE_NAMESPACE="recorder-rotation-proof-v1",
               DXMT_PIPELINE_CACHE_PREWARM_MS="0", DXMT_PIPELINE_CACHE_LOG=str(output / "rotation"),
               DXMT_PIPELINE_CACHE_LOG_SEGMENT_BYTES="4096", ASAN_OPTIONS="detect_leaks=0")
    command = [str(proof / "probe"), str(proof / "fixture.metallib"), nonce, "burst"]
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=90)
    (output / "stdout.json").write_text(result.stdout)
    (output / "stderr.log").write_text(result.stderr)
    assert result.returncode == 0, f"Recorder burst failed; inspect {output}"
    decoded = json.loads(result.stdout)
    summaries = list(output.glob("rotation-*.summary.json"))
    assert len(summaries) == 1, summaries
    summary = json.loads(summaries[0].read_text())
    stem = summaries[0].name.removesuffix(".summary.json")
    parts = [output / f"{stem}{suffix}.jsonl" for suffix in (".2", ".1", "")]
    records = []
    for part in parts:
        raw = part.read_bytes()
        assert raw.endswith(b"\n") and len(raw) <= 4096, (part, len(raw))
        records.extend(json.loads(line) for line in raw.splitlines())
    assert summary["detail_rotations"] >= 3, summary
    assert summary["diagnostic_io_errors"] == 0, summary
    assert summary["recorder"]["recipe_files"] == decoded["final"]["recipe_files"] == 2304, summary
    assert summary["recorder"]["pending_records"] == 0, summary
    assert summary["recorder"]["diagnostic_drops"] > 0, "Burst should disclose deliberate diagnostic overflow"
    assert records[-1]["event"] == "summary", records[-1]
    assert records[-1]["recipes_persisted"] == 2304, records[-1]
    assert len({row["native_pid"] for row in records}) == 1
    assert all(a["unix_ms"] <= b["unix_ms"] for a, b in zip(records, records[1:])), "Retained order changed"
    after = {name: digest(native / name) for name in before}
    report = dict(passed=True, original_proof=str(proof), architecture=original["architecture"],
                  sanitized=original["sanitized"], production_source_sha256=before,
                  source_changed_during_run=after != before,
                  binary_sha256={name: digest(proof / name) for name in ("probe", "librecorder_test.dylib", "fixture.metallib")},
                  part_limit_bytes=4096, parts={p.name: p.stat().st_size for p in parts},
                  retained_rows=len(records), final_summary=summary)
    assert before == after, "Production source changed during proof"
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(dict(output=str(output), passed=True, rotations=summary["detail_rotations"],
                          recipes=summary["recorder"]["recipe_files"],
                          diagnostic_drops=summary["recorder"]["diagnostic_drops"],
                          io_errors=summary["diagnostic_io_errors"]), indent=2))


if __name__ == "__main__":
    main()
