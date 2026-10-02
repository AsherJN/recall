#!/usr/bin/env python3
"""Launch the staged GPL Wine 11 experiment in its separate APFS-cloned prefix."""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
ENGINE = ROOT / "runtime/soju-engine-v1.5"
PREFIX = ROOT / "runtime/prefix-cx26"


CANVAS_DRAWABLES_DEFAULT = 3


MEMORY_AVAILABLE_WARN_MIB = 4096
MEMORY_COMPRESSOR_WARN_MIB = 4096
MEMORY_SWAP_WARN_MIB = 1024


def memory_preflight():
    """Host memory state before launch: the 2026-09-13 cold match froze for 1-2 s
    whenever the game ran with under 300 MiB free and 6 GiB in the compressor."""
    result = dict(page_bytes=16384, available_mib=None, free_mib=None, inactive_mib=None, compressor_mib=None,
                  swap_used_mib=None, top_processes=[], warning=None)
    try:
        text = subprocess.run(["/usr/bin/vm_stat"], capture_output=True, text=True, timeout=5).stdout
        match = re.search(r"page size of (\d+)", text)
        page = int(match.group(1)) if match else 16384
        pages = {}
        for line in text.splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            value = value.strip().rstrip(".")
            if value.isdigit():
                pages[key.strip().strip('"')] = int(value)
        mib = lambda key: pages.get(key, 0) * page // 2**20
        result.update(page_bytes=page, free_mib=mib("Pages free"), inactive_mib=mib("Pages inactive"),
                      compressor_mib=mib("Pages occupied by compressor"),
                      available_mib=mib("Pages free") + mib("Pages inactive") + mib("Pages speculative") + mib("Pages purgeable"))
    except Exception:  # a mocked or restricted subprocess must never block a launch
        pass
    try:
        swap = subprocess.run(["/usr/sbin/sysctl", "-n", "vm.swapusage"], capture_output=True, text=True, timeout=5).stdout
        match = re.search(r"used = ([\d.]+)M", swap)
        if match:
            result["swap_used_mib"] = int(float(match.group(1)))
    except Exception:  # a mocked or restricted subprocess must never block a launch
        pass
    try:
        rows = subprocess.run(["/bin/ps", "-axm", "-o", "rss=,comm="], capture_output=True, text=True, timeout=5).stdout.splitlines()
        for row in rows[:8]:
            parts = row.strip().split(None, 1)
            if len(parts) == 2 and parts[0].isdigit():
                result["top_processes"].append(dict(resident_mib=int(parts[0]) // 1024, name=os.path.basename(parts[1])))
    except Exception:  # a mocked or restricted subprocess must never block a launch
        pass
    reasons = []
    if result["available_mib"] is not None and result["available_mib"] < MEMORY_AVAILABLE_WARN_MIB:
        reasons.append(f"only {result['available_mib']} MiB available")
    if result["compressor_mib"] is not None and result["compressor_mib"] > MEMORY_COMPRESSOR_WARN_MIB:
        reasons.append(f"{result['compressor_mib']} MiB already compressed")
    if result["swap_used_mib"] is not None and result["swap_used_mib"] > MEMORY_SWAP_WARN_MIB:
        reasons.append(f"{result['swap_used_mib']} MiB swapped out")
    result["warning"] = "; ".join(reasons) or None
    return result


def memory_report(preflight):
    top = ", ".join(f"{p['name']} {p['resident_mib']} MiB" for p in preflight.get("top_processes", [])[:6])
    line = (f"Memory before launch: {preflight.get('available_mib')} MiB available, {preflight.get('compressor_mib')} MiB compressed, "
            f"{preflight.get('swap_used_mib')} MiB swap used. Largest resident: {top or 'unknown'}")
    if preflight.get("warning"):
        line += (f"\nMEMORY PRESSURE: {preflight['warning']}. The game needs about 5 GiB; under pressure macOS pages it out"
                 " mid-match (1-2 s freezes on 2026-09-13). Quit large apps first (VS Code, browsers) or use --ignore-memory.")
    return line


def build_environment(backend, engine, prefix, *, profile="baseline", performance=False,
                      no_msync=False, stamp=None, source_build=False, measure=False,
                      pipeline_cache=True, pipeline_prewarm=True, resolution=1080,
                      drawables=CANVAS_DRAWABLES_DEFAULT, pacing=False, framebuffer_only=False,
                      overlay=False, trace_resources=False):
    """Explicit session environment, also used by isolated graphics diagnostics."""
    if measure and (backend != "dxmt" or not source_build):
        raise ValueError("Measured capture requires the local DXMT source build.")
    if measure and performance:
        raise ValueError("Choose measured capture or full HUD diagnostics.")
    if trace_resources and not measure:
        raise ValueError("Resource tracing requires measured capture.")
    if drawables not in (2, 3):
        raise ValueError("The fullscreen canvas layer supports two or three drawables.")
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("DXMT_", "MTL_HUD_")) or key in (
            "WINEDLLOVERRIDES", "WINEDLLPATH", "CX_APPLEGPTK_LIBD3DSHARED_PATH",
            "MTL_SHADER_VALIDATION", "MTL_DEBUG_LAYER", "MTL_CAPTURE_ENABLED",
            "DYLD_INSERT_LIBRARIES",
        ):
            env.pop(key)
    env.update(
        WINEPREFIX=str(prefix), WINESERVER=str(engine / "bin/wineserver"),
        WINELOADER=str(engine / "bin/wine"),
        WINEDEBUG="-all,err+all" if performance else "-all",
        WINEMSYNC="0" if no_msync else "1", WINEESYNC="0",
        ROSETTA_ADVERTISE_AVX="1", WINE_SIMULATE_WRITECOPY="1",
        CX_ACTIVE_GRAPHICS_BACKEND=backend, CX_GRAPHICS_BACKEND=backend,
        CX_APPLEGPTK_LIBD3DSHARED_PATH=str(engine / "lib/external/libd3dshared.dylib"),
        DYLD_FALLBACK_LIBRARY_PATH=str(engine / "lib") + ":/usr/lib",
    )
    if backend == "dxmt":
        config_name = "dxmt-ow2.conf"
        if profile == "smooth60":
            config_name = "dxmt-source60.conf" if source_build else "dxmt-smooth60.conf"
        if source_build and profile == "smooth60" and resolution == 1200:
            config_name = "dxmt-source60-1200.conf"
        config = ROOT / "config" / config_name
        if not config.is_file() or not (engine / "lib/wine/x86_64-unix/winemetal.so").is_file():
            raise SystemExit("DXMT config and installed libraries are required.")
        env.update(
            WINEDLLOVERRIDES="d3d11,dxgi,d3d10core,winemetal=b;d3d12=",
            DXMT_CONFIG_FILE=windows_path(config),
            DXMT_SHADER_CACHE_PATH=str(ROOT / "runtime/dxmt-shader-cache"),
            DXMT_USE_DEFAULT_METAL_CACHE="1",
            DXMT_LOG_LEVEL="info" if performance else "error",
            DXMT_LOG_PATH="none",
        )
        if source_build and profile == "smooth60":
            # Read by the private native window driver for the registered
            # fullscreen canvas layer. Three matches Core Animation's default and
            # the windowed path; two reproduces the 2026-09-12 baseline for A/B runs.
            env["DXMT_CANVAS_DRAWABLES"] = str(drawables)
            # Overlay presentation window (opt-in, --overlay): the game's Metal
            # view is hosted in a plain borderless window above the Wine window
            # while fullscreen (see CANDIDATE_V4.md). Off keeps the composited path.
            env["DXMT_CANVAS_OVERLAY"] = "1" if overlay else "0"
        extra = []
        if source_build and profile == "smooth60" and pacing:
            # Just-in-time pacing in the translator's PresentBoundary (see CANDIDATE_V3.md).
            extra.append("dxgi.presentPacing=True")
        if source_build and profile == "smooth60" and framebuffer_only:
            extra.append("dxgi.framebufferOnly=True")
        if extra:
            # Extra config lines override the profile file; the translator splits on ';'.
            env["DXMT_CONFIG"] = ";".join(extra)
        if source_build and profile == "smooth60" and pipeline_cache:
            env.update(
                DXMT_PIPELINE_CACHE_PATH=str(ROOT / "runtime/dxmt-pipeline-cache-source"),
                DXMT_PIPELINE_CACHE_NAMESPACE="ow2-source-v1",
                DXMT_PIPELINE_CACHE_PREWARM_MS="10000" if pipeline_prewarm else "0",
                DXMT_PIPELINE_CACHE_PREWARM_LIMIT="128",
                DXMT_PIPELINE_CACHE_PREFER_EXPENSIVE="1",
            )
        if performance:
            env.update(DXMT_FRAME_LOG=windows_path(ROOT / "logs/dxmt" / f"frames-{stamp}"),
                       DXMT_LOG_PATH=windows_path(ROOT / "logs/dxmt" / stamp))
        elif measure:
            paths = measurement_paths(stamp)
            env.update(DXMT_FRAME_LOG=windows_path(paths["frame_prefix"]),
                       DXMT_GEOMETRY_LOG=windows_path(paths["geometry_prefix"]),
                       DXMT_WINDOW_LOG=windows_path(paths["window_prefix"]),
                       DXMT_CANVAS_LOG=str(paths["canvas_prefix"]),
                       DXMT_SHADER_LOG=windows_path(paths["shader_prefix"]),
                       # The display logger executes in the native bridge.
                       DXMT_DISPLAY_LOG=str(paths["display_prefix"]))
            # Per-call resource timing observed over 190 million Map/Unmap/use
            # operations in the last session. Keep benchmark frame/display
            # timestamps and process counters; enable deep API tracing explicitly.
            if trace_resources:
                env["DXMT_RESOURCE_LOG"] = windows_path(paths["resource_ops_prefix"])
            if "DXMT_PIPELINE_CACHE_PATH" in env:
                env["DXMT_PIPELINE_CACHE_LOG"] = str(paths["pipeline_cache_prefix"])
    if performance:
        env.update(MTL_HUD_ENABLED="1", MTL_HUD_LOG_ENABLED="1",
                   MTL_HUD_LOG_SHADER_ENABLED="1", MTL_HUD_SHOW_VALUE_RANGE="1")
    return env


def running_experiment_servers():
    """Inspect executable paths only; never read client arguments or credentials."""
    output = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    servers = []
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            continue
        path = Path(fields[1])
        if path.name == "wineserver" and path.resolve().is_relative_to(ROOT):
            servers.append(int(fields[0]))
    return servers


def windows_path(path):
    """This experiment's Z: drive maps to the macOS filesystem root."""
    return "Z:" + str(path.resolve()).replace("/", "\\")


def validate_source_runtime(engine, prefix, require_v1=False, allow_installing=False):
    stage=ROOT/'logs/dxmt/v1-stage.json'
    if not allow_installing and stage.exists() and json.loads(stage.read_text()).get('status')=='installing':
        raise RuntimeError('An interrupted v1 installation must be recovered before launch')
    path=engine/'v1-window-manifest.json'
    if not path.exists():
        if require_v1:raise RuntimeError('The v1 candidate has not been installed')
        return
    build=json.loads((engine/'local-build-manifest.json').read_text())
    for name,expected in build['files'].items():
        if hashlib.sha256((engine/'lib/wine'/name).read_bytes()).hexdigest()!=expected:
            raise RuntimeError('A source runtime library differs from its staged manifest')
    native=json.loads(path.read_text())
    if hashlib.sha256((engine/'lib/wine/x86_64-unix/winemac.so').read_bytes()).hexdigest()!=native['driver_sha256']:
        raise RuntimeError('The native window driver differs from its staged manifest')
    for name,expected in native.get('dependencies',{}).items():
        if hashlib.sha256((engine/f'lib/wine/x86_64-unix/{name}.so').read_bytes()).hexdigest()!=expected:
            raise RuntimeError('A native Wine dependency differs from the validated driver build')
    if hashlib.sha256((prefix/'drive_c/windows/system32/winemetal.dll').read_bytes()).hexdigest()!=build['files']['x86_64-windows/winemetal.dll']:
        raise RuntimeError('The prefix and engine bridge versions differ')


def measurement_paths(stamp):
    folder = ROOT / "logs/dxmt" / f"measured-{stamp}"
    return dict(frame_prefix=folder / "frames", geometry_prefix=folder / "geometry",
                resource_ops_prefix=folder / "resource-ops",
                window_prefix=folder / "windows",
                canvas_prefix=folder / "canvas",
                shader_prefix=folder / "shaders", display_prefix=folder / "display",
                pipeline_cache_prefix=folder / "pipeline-cache",
                resources=folder / "resources.jsonl",
                session_status=folder / "session-status.json",
                markers=folder / "session-markers.jsonl",
                collector_log=folder / "resource-collector.log")


def start_resource_capture(engine, paths, *, prefix=None, session_seconds=21600, hitch_stacks=False):
    """Detach a bottle-scoped collector; calls without prefix retain legacy mode."""
    import measure_resources as resources
    session = None
    if prefix is not None:
        deadline = time.monotonic() + 10
        candidate, stable_since = None, None
        while time.monotonic() < deadline:
            try:
                observed = resources.find_session_server(engine, prefix)
            except (OSError, subprocess.SubprocessError, RuntimeError):
                # A transient query failure during Battle.net startup should
                # use the remaining discovery window, never attach by guess.
                observed = None
            now = time.monotonic()
            if observed != candidate:
                candidate, stable_since = observed, now if observed else None
            # Wine briefly exposes its startup parent with the same executable
            # and prefix cwd before daemonizing. Bind only a stable identity;
            # otherwise the collector ends as soon as that parent exits.
            if candidate and stable_since is not None and now - stable_since >= 2:
                session = candidate
                break
            time.sleep(min(.2, max(0, deadline - time.monotonic())))
        if session is None:
            raise RuntimeError("The exact Wine bottle server was not found")
    arguments = [sys.executable, str(ROOT / "scripts/measure_resources.py"),
                 "--engine", engine.name, "--output", str(paths["resources"])]
    if hitch_stacks:
        arguments.append('--hitch-stacks')
    if session:
        arguments.extend(["--follow-session", "--session-pid", str(session["pid"]),
                          "--session-start", session["start_token"], "--prefix", str(prefix),
                          "--session-seconds", str(session_seconds)])
    else:
        arguments.extend(["--seconds", "900", "--wait-for-game", "600"])
    paths["resources"].parent.mkdir(parents=True, exist_ok=True)
    with paths["collector_log"].open("xb") as stream:
        collector = subprocess.Popen(
            arguments,
            cwd=ROOT, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    result = dict(collector_pid=collector.pid, startup_confirmed=False,
                  **{key: str(path) for key, path in paths.items()})
    if session:
        result.update(mode="follow_session", session=session, capture_seconds=session_seconds,
                      rotation=dict(part_bytes=resources.RESOURCE_PART_BYTES, backups=resources.RESOURCE_BACKUPS))
        # A detached Popen alone is not proof that the collector acquired its
        # lease and opened the output. Wait for its small atomic status file.
        status_path = paths["resources"].parent / "session-status.json"
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if collector.poll() is not None:
                break
            if status_path.is_file():
                status = json.loads(status_path.read_text())
                if status.get("collector_pid") == collector.pid and status.get("session") == session:
                    result["startup_confirmed"] = (status.get("status") in ("starting", "running")
                                                   and collector.poll() is None)
                    break
            time.sleep(.1)
        if not result["startup_confirmed"]:
            result["warning"] = "collector_startup_not_confirmed"
        resources.atomic_json(ROOT / "logs/dxmt/active-measurement.json", result)
    else:
        result.update(mode="legacy_first_game", wait_for_game_seconds=600, capture_seconds=900)
    return result


def background_snapshot(limit=12):
    """Largest resident processes at launch, names only; documents session conditions."""
    rows = []
    try:
        output = subprocess.check_output(["ps", "-axo", "rss=,pcpu=,comm="], text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return rows
    for line in output.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        try:
            rows.append(dict(rss_mib=round(int(parts[0]) / 1024, 1), cpu_percent=float(parts[1]),
                             name=parts[2].replace("\\", "/").rsplit("/", 1)[-1][:64]))
        except ValueError:
            continue
    rows.sort(key=lambda row: -row["rss_mib"])
    return rows[:limit]


def power_state():
    try:
        battery = subprocess.check_output(["pmset", "-g", "batt"], text=True, timeout=5).splitlines()
    except (OSError, subprocess.SubprocessError):
        return {}
    return dict(source=battery[0].strip() if battery else "", detail=battery[1].strip() if len(battery) > 1 else "")


def start_battlenet_closer(engine, prefix, stamp, grace_seconds=25):
    """Detach the watcher that exits the Battle.net client once Overwatch runs.

    The idle client measured about 1.4 GB and 1.5 CPU cores behind the game on
    2026-09-12. The watcher signals only client processes whose mapped files
    belong to this engine and prefix; Overwatch, the update Agent, the Wine
    server and other prefixes' clients are never touched.
    """
    log = ROOT / "logs/dxmt" / f"battlenet-closer-{stamp}.json"
    log.parent.mkdir(parents=True, exist_ok=True)
    closer = subprocess.Popen(
        [sys.executable, str(ROOT / "scripts/battlenet_closer.py"), "--engine", str(engine),
         "--prefix", str(prefix), "--grace-seconds", str(grace_seconds), "--log", str(log)],
        cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True)
    return dict(enabled=True, closer_pid=closer.pid, grace_seconds=grace_seconds, log=str(log))


def prepare_source_pipelines():
    """The preparation module preserves the original cache on ordinary failure."""
    try:
        from prepare_dxmt_pipelines import prepare_before_launch, PipelinePreparationUnsafeError
    except ImportError:
        return dict(status="skipped", reason="preparation_helper_unavailable")
    try:
        return prepare_before_launch()
    except PipelinePreparationUnsafeError:
        raise SystemExit("Pipeline cache publication could not be verified; launch stopped to preserve recovery state.")
    except Exception as exc:
        # Do not print exception text, inherited environment, or process args.
        return dict(status="failed", reason=type(exc).__name__)


def stop_clients():
    """Switch only when no game is running; target our two prefixes explicitly."""
    output = subprocess.check_output(["ps", "-axo", "comm="], text=True)
    if any(line.strip().endswith("Overwatch.exe") for line in output.splitlines()):
        raise SystemExit("Overwatch is running. Exit it normally before switching graphics backends.")
    for engine, prefix in (
        (ENGINE, PREFIX),
        (ROOT / "runtime/soju-engine-dxmt-ow2-v0.2", ROOT / "runtime/prefix-dxmt-ow2-v0.2"),
        (ROOT / "runtime/soju-engine-dxmt-local", ROOT / "runtime/prefix-dxmt-local"),
    ):
        if not prefix.is_dir() or not (engine / "bin/wineserver").is_file():
            continue
        env = os.environ.copy()
        env.update(WINEPREFIX=str(prefix), DYLD_FALLBACK_LIBRARY_PATH=str(engine / "lib") + ":/usr/lib")
        stopped = subprocess.run([str(engine / "bin/wineserver"), "-k"], env=env, timeout=15)
        # This Wine build returns 1 when that prefix has no server. Still wait
        # below; a failed stop of a live server must time out rather than launch.
        if stopped.returncode not in (0, 1):
            stopped.check_returncode()
        subprocess.run([str(engine / "bin/wineserver"), "-w"], env=env, check=True, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    diagnostics = parser.add_mutually_exclusive_group()
    diagnostics.add_argument("--performance", action="store_true",
                             help="Enable Apple's Metal HUD and frame/shader logging for this session.")
    diagnostics.add_argument("--measure", action="store_true",
                             help="Measure the local DXMT build with frame logs and bounded resource capture, without HUD.")
    parser.add_argument("--trace-resources", action="store_true",
                        help="With --measure, trace individual resource/Map calls (diagnosis; adds overhead).")
    parser.add_argument("--hitch-stacks", action="store_true",
                        help="With --measure, sample stacks on stalls (can perturb gameplay; off for benchmarks).")
    parser.add_argument("--backend", choices=("d3dmetal", "dxmt"), default="d3dmetal",
                        help="Select the original D3DMetal environment or isolated DXMT fork experiment.")
    parser.add_argument("--check", action="store_true",
                        help="Validate launch files and show the selection without launching.")
    parser.add_argument("--restart-client", action="store_true",
                        help="Close this experiment's Battle.net sessions before launching; refuses while Overwatch runs.")
    parser.add_argument("--no-msync", action="store_true",
                        help="Diagnostic: use Wine's server synchronization instead of msync.")
    parser.add_argument("--no-pipeline-cache", action="store_true",
                        help="Disable complete-pipeline reuse and learning for a controlled source-build comparison.")
    parser.add_argument("--no-pipeline-prewarm", action="store_true",
                        help="Learn/reuse pipelines without offline or in-game startup preparation.")
    parser.add_argument("--profile", choices=("baseline", "smooth60"), default="baseline",
                        help="DXMT profile name; local source smooth60 now uses uncapped presentation, while the stock smooth60 profile remains at 60 FPS.")
    parser.add_argument("--source-build", action="store_true",
                        help="Use the separately staged local DXMT build; refuses if not installed.")
    parser.add_argument('--resolution',type=int,choices=(1080,1200),
                        help='V1 logical canvas height; width is 1920. Requires the local smooth60 build.')
    parser.add_argument('--drawables', type=int, choices=(2, 3), default=CANVAS_DRAWABLES_DEFAULT,
                        help='Fullscreen canvas Metal drawable count; 2 reproduces the 2026-09-12 baseline for comparison.')
    parser.add_argument('--keep-battlenet', action='store_true',
                        help='Leave the Battle.net client running behind the game instead of exiting it after launch.')
    parser.add_argument('--overlay', action='store_true',
                        help='Diagnostic overlay presentation window; known focus recovery failure, excluded from alpha QA (see CANDIDATE_V6.md).')
    parser.add_argument('--ignore-memory', action='store_true',
                        help='Launch without pausing on the memory-pressure warning.')
    parser.add_argument('--pacing', action='store_true',
                        help='Translator just-in-time pacing: delay the return from Present so the next frame is built as late as possible.')
    parser.add_argument('--framebuffer-only', action='store_true',
                        help='Mark the presentation layer framebuffer-only (Core Animation flip eligibility experiment).')
    parser.add_argument('--frame-cap', type=int,
                        help='Explicitly set the saved game FPS limit (30..600; 600 is the game ceiling). Omit to preserve your in-game choice.')
    args = parser.parse_args()
    if args.resolution and not (args.source_build and args.profile == 'smooth60'):
        parser.error('--resolution requires --source-build --profile smooth60')
    if args.backend != "dxmt" and (args.profile != "baseline" or args.source_build):
        parser.error("The smooth60 profile and local source build require --backend dxmt.")
    if args.measure and (args.backend != "dxmt" or not args.source_build):
        parser.error("--measure requires --backend dxmt --source-build.")
    if (args.trace_resources or args.hitch_stacks) and not args.measure:
        parser.error("--trace-resources and --hitch-stacks require --measure.")
    engine = ENGINE if args.backend == "d3dmetal" else ROOT / "runtime/soju-engine-dxmt-ow2-v0.2"
    if args.source_build:
        engine = ROOT / "runtime/soju-engine-dxmt-local"
        if not (engine / "local-build-manifest.json").is_file():
            raise SystemExit("Local DXMT has not been built and staged. Use the regular Smooth 60 shortcut for now.")
    prefix = PREFIX if args.backend == "d3dmetal" else ROOT / "runtime/prefix-dxmt-ow2-v0.2"
    if args.source_build:
        prefix = ROOT / "runtime/prefix-dxmt-local"
        validate_source_runtime(engine,prefix,require_v1=args.resolution is not None)
    client = prefix / "drive_c/Program Files (x86)/Battle.net/Battle.net.exe"
    if not client.is_file() or not (engine / "bin/wine").is_file():
        raise SystemExit("The staged engine and cloned Battle.net environment are required.")
    # The user explicitly waived the 5 GiB launch guard for this experiment.
    # Record actual headroom; cache and telemetry retain their own size bounds.
    free_bytes_at_launch = shutil.disk_usage(ROOT).free
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    env = build_environment(args.backend, engine, prefix, profile=args.profile,
                            performance=args.performance, no_msync=args.no_msync,
                            stamp=stamp, source_build=args.source_build, measure=args.measure,
                            pipeline_cache=not args.no_pipeline_cache,
                            pipeline_prewarm=not args.no_pipeline_prewarm,resolution=args.resolution or 1080,
                            drawables=args.drawables, pacing=args.pacing, framebuffer_only=args.framebuffer_only,
                            overlay=args.overlay, trace_resources=args.trace_resources)
    preflight = memory_preflight()
    if args.check:
        print(f"Canvas overlay window: {env.get('DXMT_CANVAS_OVERLAY', 'driver default')}")
        print(memory_report(preflight))
        print(f"Validated {args.backend}: engine={engine.name}, prefix={prefix.name}")
        print(f"Profile: {args.profile}; msync={env['WINEMSYNC']}; diagnostics={args.performance}; measurement={args.measure}")
        print(f"Pipeline reuse: {'DXMT_PIPELINE_CACHE_PATH' in env}; startup preparation budget: {env.get('DXMT_PIPELINE_CACHE_PREWARM_MS', '0')} ms")
        print(f"Canvas drawables: {env.get('DXMT_CANVAS_DRAWABLES', 'driver default')}; Battle.net exits after game launch: {not args.keep_battlenet}")
        print(f"Translator extra config: {env.get('DXMT_CONFIG', 'none')}; frame cap request: {args.frame_cap if args.frame_cap is not None else 'unchanged'}")
        if args.source_build:
            from set_windowed_1080 import current_frame_cap
            saved=prefix/'drive_c/users/Sikarugir/Documents/Overwatch/Settings/Settings_v0.ini'
            if saved.is_file():print(f"Saved game FPS limit: {current_frame_cap(saved.read_text())}")
        print(f"Deep resource tracing: {args.trace_resources}; intrusive stack capture: {args.hitch_stacks}")
        print(f"Running experiment Wine servers: {running_experiment_servers()}")
        return
    print(memory_report(preflight), flush=True)
    if preflight.get("warning") and not args.ignore_memory and sys.stdin.isatty():
        try:
            input("Memory pressure: close the processes above if you can, then press Return to launch (Ctrl-C aborts)... ")
        except EOFError:
            pass
    if args.restart_client:
        stop_clients()
    if running_experiment_servers():
        raise SystemExit("An experiment Wine session is already running. Close it before starting a fresh backend session.")
    selected_preferences=None
    if args.source_build and args.profile == 'smooth60':
        from set_windowed_1080 import apply_preferences
        settings=prefix/'drive_c/users/Sikarugir/Documents/Overwatch/Settings/Settings_v0.ini'
        selected_preferences=apply_preferences(settings,ROOT/'logs/dxmt',args.resolution or 1080,args.frame_cap)
        if selected_preferences.get('frame_rate_cap') is not None:
            print(f"Saved game FPS limit: {selected_preferences['frame_rate_cap']}. Change it in the game; normal launchers preserve your choice.", flush=True)
    if args.backend == "dxmt":
        (ROOT / "runtime/dxmt-shader-cache").mkdir(exist_ok=True)
        if args.performance:
            (ROOT / "logs/dxmt" / stamp).mkdir(parents=True, exist_ok=True)
        elif args.measure:
            measurement_paths(stamp)["resources"].parent.mkdir(parents=True, exist_ok=True)
    log = ROOT / "logs" / f"cx26-{args.backend}-battlenet-{stamp}.log"
    log.parent.mkdir(exist_ok=True)
    # Store only known non-sensitive configuration; never serialize the inherited
    # environment, Battle.net arguments, or account settings.
    manifest = dict(backend=args.backend, profile=args.profile, source_build=args.source_build,
                    free_bytes_at_launch=free_bytes_at_launch, five_gib_guard_waived=True,
                    engine=engine.name, prefix=prefix.name, msync=env["WINEMSYNC"],
                    diagnostics=args.performance, measurement=args.measure,
                    measurement_options=dict(resource_api_tracing=args.trace_resources, hitch_stacks=args.hitch_stacks,
                                             frame_display_method="unchanged", process_counters=args.measure),
                    render_resolution_verified=False, selected_preferences=selected_preferences,
                    canvas_drawables=env.get("DXMT_CANVAS_DRAWABLES"),
                    canvas_overlay=env.get("DXMT_CANVAS_OVERLAY"),
                    memory_preflight=preflight,
                    translator_extra_config=env.get("DXMT_CONFIG"),
                    present_pacing=bool(args.pacing), framebuffer_only=bool(args.framebuffer_only),
                    frame_rate_cap=(selected_preferences or {}).get("frame_rate_cap"),
                    battlenet_exit_on_launch=dict(enabled=not args.keep_battlenet),
                    session_conditions=dict(power=power_state(), background_processes=background_snapshot()))
    if args.backend == "dxmt":
        for name in ("d3d11.dll", "dxgi.dll"):
            path = engine / "lib/wine/x86_64-windows" / name
            manifest[name + "_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    if args.source_build:
        manifest["local_build"] = json.loads((engine / "local-build-manifest.json").read_text())
        manifest["dxmt_config"] = ("dxmt-source60-1200.conf" if args.resolution == 1200 else "dxmt-source60.conf") if args.profile == "smooth60" else "dxmt-ow2.conf"
        manifest["source_config_sha256"] = hashlib.sha256(
            (ROOT / "config" / manifest["dxmt_config"]).read_bytes()).hexdigest()
        manifest["pipeline_cache"] = dict(
            enabled="DXMT_PIPELINE_CACHE_PATH" in env,
            path=env.get("DXMT_PIPELINE_CACHE_PATH"),
            namespace=env.get("DXMT_PIPELINE_CACHE_NAMESPACE"),
            prewarm_budget_ms=int(env.get("DXMT_PIPELINE_CACHE_PREWARM_MS", "0")),
            prewarm_limit=int(env.get("DXMT_PIPELINE_CACHE_PREWARM_LIMIT", "0")),
            prefer_expensive=env.get("DXMT_PIPELINE_CACHE_PREFER_EXPENSIVE") == "1",
        )
        if "DXMT_PIPELINE_CACHE_PATH" in env and not args.no_pipeline_prewarm:
            print("Preparing previously learned pipelines before starting Battle.net…", flush=True)
            preparation = prepare_source_pipelines()
            manifest["pipeline_preparation"] = preparation
            print(f"Pipeline preparation: {preparation.get('status', 'unknown')}.", flush=True)
    log.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n")
    with log.open("wb") as stream:
        child = subprocess.Popen(
            [str(engine / "bin/wine"),
             r"C:\Program Files (x86)\Battle.net\Battle.net.exe",
             "--disable-gpu-compositing", "--from-launcher",
             "--in-process-gpu", "--use-gl=swiftshader"],
            cwd=client.parent, env=env, stdout=stream, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    print(f"Battle.net launch requested (PID {child.pid}). Log: {log}")
    if not args.keep_battlenet:
        try:
            manifest["battlenet_exit_on_launch"] = start_battlenet_closer(engine, prefix, stamp)
            print("Battle.net will exit about 25 s after Overwatch starts; run this shortcut again to play another session.")
        except (OSError, subprocess.SubprocessError) as exc:
            manifest["battlenet_exit_on_launch"] = dict(enabled=False, error=type(exc).__name__)
        log.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n")
    if args.measure:
        paths = measurement_paths(stamp)
        try:
            manifest["measurement_capture"] = start_resource_capture(engine, paths, prefix=prefix,
                                                                     hitch_stacks=args.hitch_stacks)
        except (OSError, subprocess.SubprocessError, RuntimeError, ValueError) as exc:
            manifest["measurement_capture"] = dict(error=type(exc).__name__,
                                                     **{key: str(path) for key, path in paths.items()})
            print(f"Resource collector could not start ({type(exc).__name__}); game frame logging remains enabled.")
        else:
            if manifest["measurement_capture"].get("startup_confirmed"):
                print("Measurement ready: resources follow each game launch for up to 6 hours, until this Wine bottle closes.")
            else:
                print("Resource collector startup is unconfirmed; inspect session-status.json before relying on resource coverage.")
            print(f"Measurement files: {paths['resources'].parent}")
        log.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n")
    elif args.performance:
        print("Fresh performance session started; the game will inherit diagnostics when launched through Play.")


if __name__ == "__main__":
    main()
