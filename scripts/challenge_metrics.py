#!/usr/bin/env python3
"""Compute the seven challenge metrics for one measured Overwatch session window.

Displayed-frame intervals come from consecutive valid Metal drawable
presentedTime callbacks of one native game process. Presentation delay is the
presentDrawable request to the reported display time; it excludes input,
simulation and most rendering, so it is not total input-to-display latency.
Optional --compare prints a baseline/candidate table from a saved metrics JSON.

The Present-return-to-next-display proxy pairs the previous Present's return
with the next frame's presentedTime. Actual game input sampling is not
instrumented, and presentedTime is not a physical pixel measurement. The
historical JSON keys containing input_to_photon are retained for compatibility;
these values must not be reported as measured input-to-display latency.
"""
import argparse
import csv
import datetime
import gzip
import json
from pathlib import Path
import re
import statistics
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from analyze_process_stalls import display_hitches  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def percentile(values, fraction):
    values = sorted(values)
    if not values:
        return None
    position = (len(values) - 1) * fraction
    low = int(position)
    high = min(low + 1, len(values) - 1)
    return values[low] + (values[high] - values[low]) * (position - low)


def csv_rows(paths):
    rows = []
    for path in paths:
        opener = gzip.open if path.suffix == ".gz" else open
        with opener(path, "rt", newline="") as stream:
            rows.extend(csv.DictReader(stream))
    return rows


def json_lines(paths):
    rows = []
    for path in paths:
        with path.open() as stream:
            rows.extend(json.loads(line) for line in stream if line.strip())
    return rows


def parse_time(text):
    """Accept ISO-8601 (local or with offset) or a Unix seconds number."""
    if text is None:
        return None
    try:
        return float(text)
    except ValueError:
        pass
    moment = datetime.datetime.fromisoformat(text)
    if moment.tzinfo is None:
        moment = moment.astimezone()
    return moment.timestamp()


def marker_window(folder):
    markers = json_lines(folder.glob("session-markers.jsonl"))
    starts = [m for m in markers if m.get("event") == "quickplay_entered"]
    ends = [m for m in markers if m.get("event") == "match_ended"]
    if starts and ends:
        start = datetime.datetime.fromisoformat(starts[-1]["time"]).timestamp()
        end = datetime.datetime.fromisoformat(ends[-1]["time"]).timestamp()
        if end > start:
            return start, end, "explicit_markers"
    return None


def fullscreen_focus_window(canvas):
    """Longest focused fullscreen span from the native canvas bridge log."""
    spans, active, focused, began = [], False, False, None
    for row in sorted(canvas, key=lambda r: r["unix_ms"]):
        event = row["event"]
        if event in ("enter_fullscreen", "game_fullscreen_requested"):
            active = True
        elif event in ("exit_fullscreen", "game_windowed_requested"):
            active = False
        elif event == "focus_gained":
            focused = True
        elif event == "focus_lost":
            focused = False
        now = row["unix_ms"] / 1000
        if active and focused and began is None:
            began = now
        elif not (active and focused) and began is not None:
            spans.append((began, now))
            began = None
    if began is not None:
        spans.append((began, None))
    return max(spans, key=lambda s: (s[1] or 1e18) - s[0], default=None)


def compute(folder, pid, start=None, end=None):
    display_files = sorted(p for p in folder.glob(f"display-{pid}*.csv*")
                           if re.fullmatch(fr"display-{pid}(?:\.\d+)?\.csv(?:\.gz)?", p.name))
    display = csv_rows(display_files)
    pairs, coverage = display_hitches(display, pid, minimum_ms=0)
    if not pairs:
        raise SystemExit("No consecutive valid presentation pairs for that native PID.")
    canvas = json_lines(folder.glob(f"canvas-{pid}.jsonl"))
    boundary_source = "explicit_arguments"
    if start is None or end is None:
        found = marker_window(folder)
        if found:
            start, end, boundary_source = found
        else:
            span = fullscreen_focus_window(canvas)
            if not span:
                raise SystemExit("Give --start/--end: no markers or fullscreen focus span found.")
            start = start if start is not None else span[0]
            end = end if end is not None else (span[1] or max(h["end_utc_s"] for h in pairs))
            boundary_source = "fullscreen_focus_span"
    selected = [h for h in pairs if start <= h["start_utc_s"] and h["end_utc_s"] < end]
    if not selected:
        raise SystemExit("The window contains no displayed-frame intervals.")
    intervals = [h["duration_ms"] for h in selected]
    paired = sum(intervals) / 1000
    presented = [r for r in display if int(r["native_pid"]) == pid and r["event"] == "presented"
                 and r["presented_state"] == "valid" and float(r["presented_s"]) > 0
                 and float(r["request_host_s"]) > 0]
    delays = []
    for row in presented:
        shown = float(row["unix_ms"]) / 1000 + float(row["presented_s"]) - float(row["event_host_s"])
        if start <= shown < end:
            delays.append((float(row["presented_s"]) - float(row["request_host_s"])) * 1000)
    result = dict(
        session=str(folder), native_pid=pid, boundary_source=boundary_source,
        start_utc_s=start, end_utc_s=end,
        start_local=datetime.datetime.fromtimestamp(start).astimezone().isoformat(timespec="seconds"),
        end_local=datetime.datetime.fromtimestamp(end).astimezone().isoformat(timespec="seconds"),
        requested_seconds=round(end - start, 3), paired_seconds=round(paired, 3),
        coverage_percent=round(paired / (end - start) * 100, 2),
        displayed_intervals=len(intervals),
        average_displayed_fps=round(len(intervals) / paired, 2),
        median_interval_ms=round(statistics.median(intervals), 3),
        p95_interval_ms=round(percentile(intervals, .95), 3),
        p99_interval_ms=round(percentile(intervals, .99), 3),
        gaps_over_50ms=sum(v > 50 for v in intervals),
        gaps_over_100ms=sum(v > 100 for v in intervals),
        worst_gap_ms=round(max(intervals), 3),
        median_presentation_delay_ms=round(statistics.median(delays), 3) if delays else None,
        presentation_delay_samples=len(delays),
        per_minute=[],
        display_coverage=coverage,
    )
    minute = start
    while minute < end:
        chunk = [h["duration_ms"] for h in selected if minute <= h["start_utc_s"] < min(minute + 60, end)]
        if chunk:
            result["per_minute"].append(dict(
                start_local=datetime.datetime.fromtimestamp(minute).astimezone().strftime("%H:%M"),
                fps=round(len(chunk) / (sum(chunk) / 1000), 1), over_50ms=sum(v > 50 for v in chunk),
                over_100ms=sum(v > 100 for v in chunk), max_ms=round(max(chunk), 1)))
        minute += 60
    result["latency"] = latency_chain(folder, pid, display, start, end)
    if "input_to_photon_ms" in result["latency"]:
        result["median_input_to_photon_ms"] = result["latency"]["input_to_photon_ms"]["p50"]
        result["p90_input_to_photon_ms"] = result["latency"]["input_to_photon_ms"]["p90"]
        result["display_path_over_16ms_percent"] = result["latency"]["display_path_over_16ms_percent"]
    result["context"] = context(folder, pid, start, end)
    return result


def latency_chain(folder, pid, display, start, end):
    """Present-return-to-next-display proxy for presentations shown inside the window.

    Alignment: display sequence s is the s-th Present; the frames log boundary s
    is stamped when that Present returns to the game. The check reports the
    boundary-minus-encoder-request offset so a broken pairing is visible.
    """
    frame_files = sorted(p for p in folder.glob("frames-*.csv*") if not re.search(r"events|summary", p.name))
    boundary = {}
    for r in csv_rows(frame_files):
        if "present_boundary" in r:
            boundary[int(r["present_boundary"])] = (int(r["unix_us"]) / 1e6, int(r["frame_latency_wait_us"]) / 1e3)
    if not boundary:
        return dict(note="no frames log with present boundaries in this session")
    by_seq = {}
    for r in display:
        if int(r["native_pid"]) == pid:
            by_seq.setdefault(int(r["sequence"]), {})[r["event"]] = r
    chain, waits, stages, check = [], [], dict(cpu=[], present_to_gpu_end=[], display=[]), []
    for seq in sorted(by_seq):
        d = by_seq[seq]
        p, q, g = d.get("presented"), d.get("request"), d.get("gpu_complete")
        if not (p and q and g) or p["presented_state"] != "valid" or float(p["presented_s"]) <= 0 \
                or float(g["gpu_start_s"]) <= 0 or (seq - 1) not in boundary or seq not in boundary:
            continue
        anchor = float(p["unix_ms"]) / 1000 - float(p["event_host_s"])
        photon = anchor + float(p["presented_s"])
        if not (start <= photon < end):
            continue
        resume, present_end, wait = boundary[seq - 1][0], boundary[seq][0], boundary[seq][1]
        gpu_end = anchor + float(g["gpu_end_s"])
        check.append((present_end - float(q["unix_ms"]) / 1000) * 1000)
        chain.append((photon - resume) * 1000)
        waits.append(wait)
        stages["cpu"].append((present_end - resume) * 1000)
        stages["present_to_gpu_end"].append((gpu_end - present_end) * 1000)
        stages["display"].append((photon - gpu_end) * 1000)
    if not chain:
        return dict(note="no presentations could be paired with frame boundaries")
    long_paths = sum(v > 16 for v in stages["display"])
    return dict(
        samples=len(chain),
        method="Previous Present return to next frame's Metal presentedTime; historical input_to_photon keys are a proxy only.",
        input_sampling_instrumented=False,
        physical_pixels_measured=False,
        input_to_photon_ms=dict(p10=round(percentile(chain, .1), 2), p50=round(statistics.median(chain), 2),
                                mean=round(statistics.mean(chain), 2), p90=round(percentile(chain, .9), 2),
                                p95=round(percentile(chain, .95), 2), p99=round(percentile(chain, .99), 2)),
        stage_medians_ms=dict(game_cpu_and_waits=round(statistics.median(stages["cpu"]), 2),
                              present_boundary_wait=round(statistics.median(waits), 2),
                              present_end_to_gpu_end=round(statistics.median(stages["present_to_gpu_end"]), 2),
                              gpu_end_to_photon=round(statistics.median(stages["display"]), 2)),
        display_path_over_16ms_percent=round(100 * long_paths / len(chain), 1),
        alignment_check_ms=dict(p5=round(percentile(check, .05), 2), p50=round(statistics.median(check), 2),
                                p95=round(percentile(check, .95), 2),
                                note="Present return minus encoder request; expect about -3..+8 ms"))


def context(folder, pid, start, end):
    """Workload/system context: GPU utilisation, memory, faults, pipelines, thermal, client CPU."""
    out = {}
    process_rows = [r for r in csv_rows(sorted(folder.glob("resources*.process*.csv*")))
                    if r.get("pid") == str(pid) and r.get("error") == "0"
                    and start <= int(r["unix_us"]) / 1e6 <= end]
    if len(process_rows) > 1:
        first, last = process_rows[0], process_rows[-1]
        seconds = (int(last["unix_us"]) - int(first["unix_us"])) / 1e6
        cpu = (int(last["user_ns"]) + int(last["system_ns"]) - int(first["user_ns"]) - int(first["system_ns"])) / 1e9
        ticks = {k: int(last[k]) - int(first[k]) for k in ("cpu_user_ticks_u32", "cpu_system_ticks_u32", "cpu_idle_ticks_u32")}
        total = sum(ticks.values()) or 1
        out.update(
            game_cpu_cores=round(cpu / seconds, 2) if seconds else None,
            host_busy_percent=round((1 - ticks["cpu_idle_ticks_u32"] / total) * 100, 1),
            host_kernel_percent=round(ticks["cpu_system_ticks_u32"] / total * 100, 1),
            game_footprint_mib=[round(int(first["footprint_bytes"]) / 2**20), round(int(last["footprint_bytes"]) / 2**20)],
            game_resident_mib=[round(int(first["resident_bytes"]) / 2**20), round(int(last["resident_bytes"]) / 2**20)],
            game_faults=int(last["faults_u32"]) - int(first["faults_u32"]),
            system_compressions=int(last["vm_compressions"]) - int(first["vm_compressions"]),
            system_decompressions=int(last["vm_decompressions"]) - int(first["vm_decompressions"]),
            system_swapins=int(last["vm_swapins"]) - int(first["vm_swapins"]),
            system_swapouts=int(last["vm_swapouts"]) - int(first["vm_swapouts"]),
            compressor_mib=[round(int(first["vm_compressor_pages"]) * int(first["vm_page_bytes"]) / 2**20),
                            round(int(last["vm_compressor_pages"]) * int(last["vm_page_bytes"]) / 2**20)],
            free_memory_mib_min=round(min(int(r["vm_free_pages"]) * int(r["vm_page_bytes"]) for r in process_rows) / 2**20))
    gpu, clients, thermal, client_rows = [], [], [], 0
    for row in json_lines(folder.glob("resources.jsonl")):
        moment = datetime.datetime.fromisoformat(row["time"]).timestamp()
        if start <= moment <= end:
            util = row.get("gpu_system_wide", {}).get("device_utilization_percent")
            if util is not None:
                gpu.append(util)
            if "client_processes" in row:
                client_rows += 1
                clients.append(dict(cpu=sum(c.get("cpu_percent", 0) for c in row["client_processes"]),
                                    rss=sum(c.get("rss_mib", 0) for c in row["client_processes"]),
                                    count=len(row["client_processes"])))
            if row.get("thermal"):
                thermal.append(row["thermal"])
    if gpu:
        out["gpu_device_utilization_percent"] = dict(mean=round(statistics.mean(gpu), 1), p95=round(percentile(gpu, .95), 1))
    if client_rows:
        out["battlenet_client_processes"] = dict(
            samples=client_rows, mean_cpu_percent=round(statistics.mean(c["cpu"] for c in clients), 1),
            mean_rss_mib=round(statistics.mean(c["rss"] for c in clients)), mean_process_count=round(statistics.mean(c["count"] for c in clients), 1),
            note="ps lifetime CPU averages of Battle.net.exe/Agent.exe rows; zero rows mean the client had exited")
    else:
        out["battlenet_client_processes"] = "not recorded by this session's collector"
    if thermal:
        limits = [t.get("cpu_speed_limit_percent") for t in thermal if t.get("cpu_speed_limit_percent") is not None]
        out["thermal_cpu_speed_limit_min_percent"] = min(limits) if limits else None
    creates = [j for j in json_lines(folder.glob(f"pipeline-cache-{pid}*.jsonl"))
               if j.get("event") == "runtime" and start <= j.get("unix_ms", 0) / 1000 <= end]
    if creates:
        expensive = [j for j in creates if j.get("cost_us", 0) > 16667]
        out["pipeline_creates"] = dict(total=len(creates), over_16_7ms=len(expensive),
                                       unknown_at_launch=sum(1 for j in creates if j.get("known_at_launch") is False),
                                       max_ms=round(max(j["cost_us"] for j in creates) / 1000, 1))
    return out


METRICS = [("Average displayed FPS", "average_displayed_fps", "higher"),
           ("p95 displayed-frame interval (ms)", "p95_interval_ms", "lower"),
           ("p99 displayed-frame interval (ms)", "p99_interval_ms", "lower"),
           ("Gaps over 50 ms", "gaps_over_50ms", "lower"),
           ("Gaps over 100 ms", "gaps_over_100ms", "lower"),
           ("Worst displayed-frame gap (ms)", "worst_gap_ms", "lower"),
           ("Median presentation-request-to-display delay (ms)", "median_presentation_delay_ms", "lower"),
           ("Median Present-return to next display proxy (ms)", "median_input_to_photon_ms", "lower"),
           ("p90 Present-return to next display proxy (ms)", "p90_input_to_photon_ms", "lower"),
           ("Display-path frames over 16 ms (%)", "display_path_over_16ms_percent", "lower")]


def table(baseline, candidate):
    lines = ["| Metric | Baseline | Candidate | Better? |", "|---|---:|---:|---|"]
    for label, key, direction in METRICS:
        a, b = baseline.get(key), candidate.get(key)
        if a is None or b is None:
            verdict = "n/a"
        else:
            verdict = "yes" if ((b > a) if direction == "higher" else (b < a)) else ("equal" if a == b else "no")
        lines.append(f"| {label} | {a} | {b} | {verdict} |")
    lines.append(f"| Window (s, coverage %) | {baseline['requested_seconds']} ({baseline['coverage_percent']}) | "
                 f"{candidate['requested_seconds']} ({candidate['coverage_percent']}) | |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", type=Path, help="Measured session folder (logs/dxmt/measured-*).")
    parser.add_argument("--pid", type=int, help="Native game PID (display-<pid>.csv).")
    parser.add_argument("--start", help="Window start: ISO-8601 local time or Unix seconds.")
    parser.add_argument("--end", help="Window end: ISO-8601 local time or Unix seconds.")
    parser.add_argument("--output", type=Path, help="Write the metrics JSON here.")
    parser.add_argument("--compare", type=Path, help="Baseline metrics JSON to print a comparison table against.")
    parser.add_argument("--candidate", type=Path, help="With --compare: candidate metrics JSON instead of computing one.")
    args = parser.parse_args()
    if args.candidate:
        candidate = json.loads(args.candidate.read_text())
    else:
        if not args.session or not args.pid:
            parser.error("--session and --pid are required unless --candidate is given")
        candidate = compute(args.session.resolve(), args.pid, parse_time(args.start), parse_time(args.end))
        if args.output:
            args.output.write_text(json.dumps(candidate, indent=2) + "\n")
    summary = {k: candidate[k] for k in ("boundary_source", "start_local", "end_local", "requested_seconds",
                                          "coverage_percent", "displayed_intervals")}
    print(json.dumps(summary))
    for label, key, _ in METRICS:
        print(f"{label}: {candidate.get(key)}")
    print("latency:", json.dumps(candidate.get("latency", {})))
    print("context:", json.dumps(candidate.get("context", {})))
    if args.compare:
        print()
        print(table(json.loads(args.compare.read_text()), candidate))


if __name__ == "__main__":
    main()
