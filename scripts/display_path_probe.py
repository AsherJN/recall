#!/usr/bin/env python3
"""Run the native presentation-timing probe and summarise the display path per configuration.

The probe (tests/presentation/display_path_probe.m) reproduces the game's
presentation pattern in a fullscreen space without Wine. This runner compiles
it, runs a list of configuration specs, samples WindowServer CPU time during
each spec, and reports the GPU-end-to-photon distribution, the share of frames
that waited more than 16 ms, photon period modes and the input-sample proxy
(cpu_start to photon) for each spec. Output lands in logs/dxmt/display-path-probe-<stamp>/.
"""
import argparse
import csv
import datetime
import json
from pathlib import Path
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "tests/presentation/display_path_probe.m"
BINARY = ROOT / "runtime/build/display-path-probe/probe"

DEFAULT_SPECS = [
    "label=game-3d,drawables=3,sync=0,size=canvas,policy=latency1",
    "label=game-2d,drawables=2,sync=0,size=canvas,policy=latency1",
    "label=sync-3d,drawables=3,sync=1,size=canvas,policy=latency1",
    "label=jit-3d,drawables=3,sync=0,size=canvas,policy=jit",
    "label=pfence-3d,drawables=3,sync=0,size=canvas,policy=pfence",
    "label=window-3d,drawables=3,sync=0,size=window,policy=latency1",
    "label=full-3d,drawables=3,sync=0,size=full,policy=latency1",
    "label=pace12.5-3d,drawables=3,sync=0,size=canvas,policy=pace,period=12.5",
]


def percentile(values, fraction):
    values = sorted(values)
    if not values:
        return None
    position = (len(values) - 1) * fraction
    low = int(position)
    high = min(low + 1, len(values) - 1)
    return values[low] + (values[high] - values[low]) * (position - low)


def build():
    BINARY.parent.mkdir(parents=True, exist_ok=True)
    if BINARY.exists() and BINARY.stat().st_mtime >= SOURCE.stat().st_mtime:
        return
    subprocess.run(["/usr/bin/clang", "-arch", "arm64", "-fobjc-arc", "-Wall", "-Wextra", "-Wno-unused-parameter",
                    "-framework", "AppKit", "-framework", "Metal", "-framework", "QuartzCore", "-framework", "CoreGraphics", "-framework", "CoreVideo",
                    "-o", str(BINARY), str(SOURCE)], check=True)


def windowserver_cpu_seconds():
    """Cumulative CPU seconds of WindowServer from ps (MM:SS.cc), or None."""
    try:
        pid = subprocess.run(["pgrep", "-x", "WindowServer"], capture_output=True, text=True, timeout=5).stdout.split()
        if not pid:
            return None
        text = subprocess.run(["ps", "-o", "time=", "-p", pid[0]], capture_output=True, text=True, timeout=5).stdout.strip()
        parts = text.split(":")
        seconds = float(parts[-1]) + 60 * float(parts[-2]) + (3600 * float(parts[-3]) if len(parts) > 2 else 0)
        return seconds
    except (subprocess.SubprocessError, ValueError, IndexError):
        return None


def summarise(rows):
    """Per-spec display-path statistics from the probe's CSV rows."""
    by_spec = {}
    for r in rows:
        by_spec.setdefault((int(r["spec_index"]), r["spec"]), []).append(r)
    out = []
    for (index, spec), items in sorted(by_spec.items()):
        valid = [r for r in items if r["completed_seen"] == "1" and r["presented_seen"] == "1" and r["main_seen"] == "1"
                 and float(r["presented"]) > 0 and float(r["gpu_end"]) > 0]
        if len(valid) < 10:
            out.append(dict(index=index, spec=spec, frames=len(items), note="too few valid presentations"))
            continue
        valid.sort(key=lambda r: int(r["frame"]))
        display = [(float(r["presented"]) - float(r["gpu_end"])) * 1000 for r in valid]
        chain = [(float(r["presented"]) - float(r["cpu_start"])) * 1000 for r in valid]
        gpu = [(float(r["gpu_end"]) - float(r["main_gpu_start"])) * 1000 for r in valid]
        request = [(float(r["presented"]) - float(r["present_commit"])) * 1000 for r in valid]
        drawable_wait = [float(r["drawable_wait_ms"]) for r in valid]
        photons = [float(r["presented"]) for r in valid]
        periods = [(b - a) * 1000 for a, b in zip(photons, photons[1:]) if 0 < b - a < 1]
        idle = [(float(b["main_gpu_start"]) - float(a["gpu_end"])) * 1000 for a, b in zip(valid, valid[1:])]
        label = dict(item.split("=", 1) for item in spec.split(",") if "=" in item).get("label", spec)
        out.append(dict(
            index=index, label=label, spec=spec, frames=len(items), valid=len(valid),
            fps=round(len(periods) / (sum(periods) / 1000), 1) if periods else None,
            gpu_ms_p50=round(statistics.median(gpu), 2),
            gpu_idle_ms_p50=round(statistics.median(idle), 2) if idle else None,
            request_to_photon_ms_p50=round(statistics.median(request), 2),
            drawable_wait_ms=dict(p50=round(statistics.median(drawable_wait), 2), p90=round(percentile(drawable_wait, .9), 2)),
            display_ms=dict(p10=round(percentile(display, .1), 2), p50=round(statistics.median(display), 2),
                            mean=round(statistics.mean(display), 2), p90=round(percentile(display, .9), 2),
                            p99=round(percentile(display, .99), 2)),
            display_over_16ms_percent=round(100 * sum(v > 16 for v in display) / len(display), 1),
            display_under_6ms_percent=round(100 * sum(v < 6 for v in display) / len(display), 1),
            chain_ms=dict(p50=round(statistics.median(chain), 2), mean=round(statistics.mean(chain), 2),
                          p90=round(percentile(chain, .9), 2)),
            period_ms=dict(p50=round(statistics.median(periods), 2), p90=round(percentile(periods, .9), 2)) if periods else None,
            period_near_8_3_percent=round(100 * sum(abs(v - 8.33) < 0.4 for v in periods) / len(periods), 1) if periods else None,
            period_near_16_7_percent=round(100 * sum(abs(v - 16.67) < 0.4 for v in periods) / len(periods), 1) if periods else None,
            unavailable_presented=sum(1 for r in items if r["presented_seen"] != "1" or float(r["presented"]) <= 0)))
    return out


def table(summary):
    lines = ["| Spec | FPS | GPU ms | idle ms | drawable wait p50/p90 | request→photon p50 | display p50 / mean / p90 | >16 ms | <6 ms | chain p50 / p90 | WindowServer CPU |",
             "|---|---:|---:|---:|---|---:|---|---:|---:|---|---:|"]
    for s in summary:
        if "note" in s:
            lines.append(f"| {s['spec']} | {s['note']} | | | | | | | | | |")
            continue
        d, c = s["display_ms"], s["chain_ms"]
        ws = s.get("windowserver_cpu_percent")
        w = s["drawable_wait_ms"]
        lines.append(f"| {s['label']} | {s['fps']} | {s['gpu_ms_p50']} | {s['gpu_idle_ms_p50']} | {w['p50']} / {w['p90']} | {s['request_to_photon_ms_p50']} | {d['p50']} / {d['mean']} / {d['p90']} | "
                     f"{s['display_over_16ms_percent']}% | {s['display_under_6ms_percent']}% | {c['p50']} / {c['p90']} | "
                     f"{'' if ws is None else str(ws) + '%'} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=8, help="Measured seconds per spec (after calibration).")
    parser.add_argument("--spec", action="append", help="Configuration spec; repeatable. Default: the standard matrix.")
    parser.add_argument("--windowed", action="store_true", help="Do not enter a fullscreen space (sanity runs).")
    parser.add_argument("--output", type=Path, help="Session folder (default logs/dxmt/display-path-probe-<stamp>).")
    args = parser.parse_args()
    build()
    specs = args.spec or DEFAULT_SPECS
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    folder = args.output or ROOT / "logs/dxmt" / f"display-path-probe-{stamp}"
    folder.mkdir(parents=True, exist_ok=True)
    csv_path = folder / "frames.csv"
    command = [str(BINARY), str(csv_path), str(args.seconds), ";".join(specs)] + (["windowed"] if args.windowed else [])
    # WindowServer CPU per spec: the probe prints "spec N done" lines to stderr as it goes.
    ws_samples = []
    before = windowserver_cpu_seconds()
    started = time.monotonic()
    process = subprocess.Popen(command, stderr=subprocess.PIPE, text=True)
    stderr_lines = []
    for line in process.stderr:
        stderr_lines.append(line.rstrip())
        if line.startswith("spec ") and " done" in line:
            after = windowserver_cpu_seconds()
            elapsed = time.monotonic() - started
            ws_samples.append((after - before) / elapsed * 100 if (after is not None and before is not None and elapsed > 0) else None)
            before, started = after, time.monotonic()
    process.wait()
    (folder / "probe.log").write_text("\n".join(stderr_lines) + "\n")
    if process.returncode != 0:
        raise SystemExit(f"probe exited with {process.returncode}; see {folder / 'probe.log'}")
    with csv_path.open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    summary = summarise(rows)
    for item, ws in zip(summary, ws_samples):
        item["windowserver_cpu_percent"] = None if ws is None else round(ws, 1)
    report = dict(stamp=stamp, seconds=args.seconds, windowed=args.windowed, specs=specs, probe_log=stderr_lines[:3],
                  summary=summary)
    (folder / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print("\n".join(stderr_lines[:1]))
    print(table(summary))
    print(f"session: {folder}")


if __name__ == "__main__":
    main()
