#!/usr/bin/env python3
"""GPU-bound fullscreen A/B of translator just-in-time pacing, without the game.

Runs the D3D11 render diagnostic in the isolated validation engine with enough
full-screen overdraw to be GPU-bound like the game (about 11-12 ms per frame),
enters the native fullscreen canvas through the real DXGI API, and records the
frames log (frame-latency wait, pacing sleep, present interval) and the display
log (input-sample-to-photon proxy). Each case runs once with pacing off and once
with pacing on. Output: logs/dxmt/pacing-ab-<stamp>/{off,on}/ and summary.json.
"""
import argparse
import datetime
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import launch_cx26 as launch  # noqa: E402
import validate_dxmt_pipeline_reuse as render  # noqa: E402
from challenge_metrics import csv_rows, json_lines, latency_chain, percentile  # noqa: E402


def wineserver(env, flag, check=False):
    subprocess.run([str(render.ENGINE / "bin/wineserver"), flag], env=env, check=check,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)


def run_case(folder, name, *, pacing, gpu_draws, seconds, height, settle, overlay=False):
    target = folder / name
    target.mkdir()
    env = launch.build_environment("dxmt", render.ENGINE, render.PREFIX, source_build=True, profile="smooth60",
                                   pipeline_cache=False, resolution=height, overlay=overlay)
    config = target / "dxmt.conf"
    config.write_text("[python.exe]\nd3d11.preferredMaxFrameRate = 0\ndxgi.maxFrameLatency = 1\n"
                      "dxgi.nativeFullscreen = True\ndxgi.sharpPresentation = True\n"
                      f"dxgi.fullscreenCanvasWidth = 1920\ndxgi.fullscreenCanvasHeight = {height}\n"
                      + ("dxgi.presentPacing = True\n" if pacing else ""))
    env.update(DXMT_CONFIG_FILE=launch.windows_path(config), DXMT_CANVAS_LOG=str(target / "canvas"),
               DXMT_DISPLAY_LOG=str(target / "display"), DXMT_FRAME_LOG=launch.windows_path(target / "frames"))
    wineserver(env, "-k")
    wineserver(env, "-w", check=True)
    checkpoints = target / "checkpoints.jsonl"
    command = checkpoints.with_suffix(".command")
    with (target / "diagnostic.log").open("w") as output:
        process = subprocess.Popen([str(render.ENGINE / "bin/wine"),
                                    launch.windows_path(ROOT / "runtime/diagnostics/python-3.13.7-embed/python.exe"),
                                    launch.windows_path(ROOT / "scripts/d3d11_render_probe_windows.py"),
                                    "--width", "1920", "--height", str(height), "--frames", "36000",
                                    "--gpu-draws", str(gpu_draws), "--canvas-probe", launch.windows_path(checkpoints)],
                                   env=env, stdout=output, stderr=subprocess.STDOUT)
        try:
            time.sleep(settle)
            command.write_text("fullscreen_on")
            time.sleep(seconds)
            command.write_text("finish")
            process.wait(timeout=90)
        finally:
            if process.poll() is None:
                process.kill()
            wineserver(env, "-k")
            wineserver(env, "-w")
    return analyse(target, pacing, seconds)


def analyse(target, pacing, seconds):
    display_files = [p for p in target.glob("display-*.csv") if re.fullmatch(r"display-\d+\.csv", p.name)]
    if not display_files:
        return dict(pacing=pacing, note="no display log")
    pid = int(re.search(r"display-(\d+)", display_files[0].name).group(1))
    display = csv_rows(display_files)
    canvas = json_lines(target.glob("canvas-*.jsonl"))
    entered = [c["unix_ms"] / 1000 for c in canvas if c["event"] == "enter_fullscreen"]
    if not entered:
        return dict(pacing=pacing, note="fullscreen never entered")
    photons = []
    for r in display:
        if r["event"] == "presented" and r["presented_state"] == "valid" and float(r["presented_s"]) > 0:
            photons.append(float(r["unix_ms"]) / 1000 + float(r["presented_s"]) - float(r["event_host_s"]))
    start, end = entered[-1] + 1.5, max(photons) - 0.3
    chain = latency_chain(target, pid, display, start, end)
    frames = [r for p in target.glob("frames*.csv") if not re.search(r"events|summary", p.name) for r in csv_rows([p])]
    frames = [r for r in frames if start <= int(r["unix_us"]) / 1e6 < end]
    waits = [int(r["frame_latency_wait_us"]) / 1000 for r in frames]
    sleeps = [int(r.get("pacing_sleep_us", 0)) / 1000 for r in frames]
    intervals = [int(r["present_interval_us"]) / 1000 for r in frames if 0 < int(r["present_interval_us"]) < 1e6]
    shown = sorted(p for p in photons if start <= p < end)
    periods = [(b - a) * 1000 for a, b in zip(shown, shown[1:]) if 0 < b - a < 1]
    stat = lambda v: dict(p50=round(statistics.median(v), 2), p90=round(percentile(v, .9), 2), max=round(max(v), 2)) if v else None
    return dict(pacing=pacing, window_seconds=round(end - start, 1), frames=len(frames),
                fps=round(len(periods) / (sum(periods) / 1000), 1) if periods else None,
                present_interval_ms=stat(intervals), frame_latency_wait_ms=stat(waits), pacing_sleep_ms=stat(sleeps),
                sleeps=sum(1 for v in sleeps if v > 0), latency=chain)


def table(cases):
    lines = ["| Case | FPS | Present interval p50 | Fence wait p50 / p90 | Pacing sleep p50 / p90 / max | Input-sample→photon p10 / p50 / p90 | Display path p50 |",
             "|---|---:|---:|---|---|---|---:|"]
    for name, c in cases.items():
        if "note" in c:
            lines.append(f"| {name} | {c['note']} | | | | | |")
            continue
        w, s, lat = c["frame_latency_wait_ms"], c["pacing_sleep_ms"], c["latency"]
        itp = lat.get("input_to_photon_ms", {})
        lines.append(f"| {name} | {c['fps']} | {c['present_interval_ms']['p50']} | {w['p50']} / {w['p90']} | {s['p50']} / {s['p90']} / {s['max']} | "
                     f"{itp.get('p10')} / {itp.get('p50')} / {itp.get('p90')} | {lat.get('stage_medians_ms', {}).get('gpu_end_to_photon')} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=20, help="Fullscreen measured seconds per case.")
    parser.add_argument("--gpu-draws", type=int, default=400, help="Full-screen draws per frame (GPU load).")
    parser.add_argument("--height", type=int, choices=(1080, 1200), default=1200)
    parser.add_argument("--settle", type=float, default=4.0, help="Seconds windowed before requesting fullscreen.")
    parser.add_argument("--cases", default="off,on", help="Comma list from off,on (order of execution).")
    parser.add_argument("--overlay", action="store_true", help="Host the diagnostic's fullscreen view in the overlay presentation window.")
    args = parser.parse_args()
    if launch.running_experiment_servers():
        raise SystemExit("Close the experiment Wine session first.")
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    folder = ROOT / "logs/dxmt" / f"pacing-ab-{stamp}"
    folder.mkdir(parents=True)
    print(folder, flush=True)
    cases = {}
    for name in args.cases.split(","):
        cases[name] = run_case(folder, name, pacing=(name == "on"), gpu_draws=args.gpu_draws, seconds=args.seconds,
                               height=args.height, settle=args.settle, overlay=args.overlay)
        print(name, json.dumps({k: v for k, v in cases[name].items() if k != "latency"}), flush=True)
    report = dict(stamp=stamp, seconds=args.seconds, gpu_draws=args.gpu_draws, height=args.height, cases=cases, overlay=args.overlay,
                  engine=render.ENGINE.name, note="Render diagnostic, not the game: GPU-bound overdraw, 2 ms simulated CPU work per frame.")
    (folder / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(table(cases))


if __name__ == "__main__":
    main()
