#!/usr/bin/env python3
"""Exercise the built pipeline cache through real Wine/D3D11 rendering.

Uses the existing diagnostic prefix, an isolated cloned engine, and new private
shader/pipeline caches. No game process or game cache is modified. Leaves the
validated engine available for reviewed publication after all checks pass.
"""
from pathlib import Path
import csv
import datetime
import hashlib
import json
import re
import shutil
import subprocess

import launch_cx26 as launch
import stage_dxmt_local as stage

ROOT = launch.ROOT
ENGINE = ROOT / "runtime/build/dxmt-local/pipeline-reuse-validated-engine"
PREFIX = ROOT / "runtime/diagnostics/prefix-window-sizing-20260911-124251"


def rows(path):
    with path.open(newline="") as stream:
        result = list(csv.DictReader(stream))
    if any(None in row or any(value is None for value in row.values()) for row in result):
        raise RuntimeError(f"Incomplete diagnostic CSV: {path.name}")
    return result


def validate_reuse_report(report):
    def summary(case):
        records = [event for event in report["runs"][case]["pipeline_cache_events"]
                   if event.get("event") == "summary"]
        assert records, f"Missing completed periodic summary for {case}"
        result = records[-1]
        # The presenter deliberately uses two function-constant variants,
        # which bypass this standard unspecialized render-pipeline cache.
        assert result["startup_done"] and result["unsupported"] == 2, (case, result)
        # This small workload must drain essential data completely. Optional
        # fixed-ring diagnostics have separate counters in the new recorder.
        assert result["persist_failures"] == 0, (case, result)
        assert result["queue_drops"] == 0, (case, result)
        recorder = result["recorder"]
        assert recorder["pending_records"] == recorder["pending_bytes"] == 0, (case, recorder)
        assert recorder["recipe_limit"] == 32768 and recorder["library_limit"] == 65536
        assert recorder["disk_limit"] == 512 * 1024 * 1024
        assert all(recorder[key] == 0 for key in
                   ("io_failures", "invalid_records", "dependency_failures", "recipe_limit_rejections",
                    "library_limit_rejections", "disk_limit_rejections", "disk_space_rejections")), (case, recorder)
        return result

    learned = summary("learn")
    assert learned["prewarmed"] == 0 and learned["archive_adds"] == 0, learned
    assert learned["runtime_creates"] >= 1 and learned["recipes_persisted"] >= 1, learned
    assert learned["runtime_creates"] == 5, learned
    prepared = summary("prepare")
    assert prepared["prewarmed"] >= 1 and prepared["hits"] >= 1, prepared
    assert prepared["runtime_creates"] == 0 and prepared["archive_adds"] >= 1, prepared
    replayed = summary("replay")
    assert replayed["archive_lookup_hits"] >= 1 and replayed["hits"] >= 1, replayed
    assert replayed["runtime_creates"] == 0, replayed
    changed = summary("new_shader")
    assert changed["runtime_creates"] >= 1, changed
    expanded = summary("prepare_new_shader")
    assert expanded["prewarmed"] == 6 and expanded["hits"] == 5, expanded
    assert expanded["runtime_creates"] == 0 and expanded["archive_adds"] == 1, expanded
    expanded_replay = summary("replay_expanded")
    assert expanded_replay["archive_lookup_hits"] == 6 and expanded_replay["hits"] == 5, expanded_replay
    assert expanded_replay["runtime_creates"] == 0 and expanded_replay["archive_adds"] == 0, expanded_replay
    assert all(summary(case)["archive_failures"] == 0 for case in
               ("learn", "prepare", "replay", "new_shader", "prepare_new_shader", "replay_expanded"))
    report["pipeline_reuse_assertions"] = "PASS: learning, complete prewarmed hits, strict archive hits, changed-shader fallback, and multi-library archive growth/replay."
    report["queue_drops_by_run"] = {
        case: summary(case)["queue_drops"] for case in
        ("learn", "prepare", "replay", "new_shader", "prepare_new_shader", "replay_expanded")
    }
    report["recorder_by_run"] = {case: summary(case)["recorder"] for case in report["queue_drops_by_run"]}


def main():
    if ENGINE.exists() or not PREFIX.is_dir():
        raise SystemExit("Expected an unused staging engine and the existing diagnostic prefix.")
    if any(line.strip().endswith("Overwatch.exe") for line in
           subprocess.check_output(["ps", "-axo", "comm="], text=True).splitlines()):
        raise SystemExit("Close Overwatch before graphics validation.")
    if shutil.disk_usage(ROOT).free < 5 * 2**30:
        raise SystemExit("At least 5 GiB free is required.")
    manifest = stage.validate_build()
    diff = subprocess.check_output(["git", "-C", str(ROOT / "runtime/source/dxmt-ow2"), "diff", "--binary"])
    assert hashlib.sha256(diff).hexdigest() == manifest["patch_sha256"]
    folder = ROOT / "logs/dxmt" / ("pipeline-reuse-validation-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    folder.mkdir()
    subprocess.run(["/bin/cp", "-cR", str(stage.ENGINE), str(ENGINE)], check=True)
    for name in stage.FILES:
        shutil.copy2(stage.INSTALL / name, ENGINE / "lib/wine" / name)
        assert hashlib.sha256((ENGINE / "lib/wine" / name).read_bytes()).hexdigest() == manifest["files"][name]
    (ENGINE / "local-build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    # This native-only cache integration must not change the PE/unix bridge ABI.
    assert hashlib.sha256((PREFIX / "drive_c/windows/system32/winemetal.dll").read_bytes()).hexdigest() == manifest["files"]["x86_64-windows/winemetal.dll"]
    shader_cache = folder / "shader-cache"
    shader_cache.mkdir()
    pipeline_cache = folder / "pipeline-cache"
    blocked = folder / "not-a-directory"
    blocked.write_text("Intentional cache failure fixture.\n")
    report = dict(engine=str(ENGINE), prefix=str(PREFIX), manifest=manifest, runs={},
                  scope="Actual D3D11/Wine 1080p rendering and pipeline reuse; not a gameplay benchmark.")
    cases = [("learn", True, 0, 240, 91), ("prepare", True, 10000, 120, 91),
             ("replay", True, 10000, 120, 91), ("new_shader", True, 10000, 120, 92),
             ("prepare_new_shader", True, 10000, 120, 92), ("replay_expanded", True, 10000, 120, 91),
             ("cache_failure", True, 10000, 120, 91), ("off", False, 0, 120, 91)]
    try:
        for name, enabled, budget, count, blue in cases:
            run_dir = folder / name
            run_dir.mkdir()
            config = run_dir / "dxmt.conf"
            config.write_text("[python.exe]\nd3d11.releaseShaderIR = True\nd3d11.preferredMaxFrameRate = 60\n"
                              "d3d11.shaderCompilerThreads = 4\nd3d11.shaderCompilerNormalPriority = True\n")
            env = launch.build_environment("dxmt", ENGINE, PREFIX, profile="smooth60", source_build=True,
                                           pipeline_cache=enabled)
            env.update(DXMT_CONFIG_FILE=launch.windows_path(config), DXMT_SHADER_CACHE_PATH=str(shader_cache))
            if enabled:
                env.update(DXMT_PIPELINE_CACHE_PATH=str(blocked / "child" if name == "cache_failure" else pipeline_cache),
                           DXMT_PIPELINE_CACHE_NAMESPACE="wine-probe-v1",
                           DXMT_PIPELINE_CACHE_PREWARM_MS=str(budget), DXMT_PIPELINE_CACHE_PREWARM_LIMIT="8",
                           DXMT_PIPELINE_CACHE_LOG=str(run_dir / "pipeline-cache"))
            for key, basename in [("DXMT_FRAME_LOG", "frames"), ("DXMT_GEOMETRY_LOG", "geometry"),
                                  ("DXMT_RESOURCE_LOG", "resource-ops"),
                                  ("DXMT_WINDOW_LOG", "windows"), ("DXMT_SHADER_LOG", "shaders")]:
                env[key] = launch.windows_path(run_dir / basename)
            env["DXMT_DISPLAY_LOG"] = str(run_dir / "display")
            with (run_dir / "probe.log").open("w") as output:
                result = subprocess.run([str(ENGINE / "bin/wine"),
                    launch.windows_path(ROOT / "runtime/diagnostics/python-3.13.7-embed/python.exe"),
                    launch.windows_path(ROOT / "scripts/d3d11_render_probe_windows.py"),
                    "--frames", str(count), "--width", "1920", "--height", "1080", "--blue", str(blue)],
                    env=env, stdout=output, stderr=subprocess.STDOUT, timeout=120)
            result.check_returncode()
            results = [json.loads(line) for line in (run_dir / "probe.log").read_text(errors="replace").splitlines()
                       if line.startswith("{")]
            probe = next(row for row in results if row.get("result") == "PASS")
            assert probe["backbuffer"] == [1920, 1080] and probe["blue"] == blue
            assert len(probe["verified_pixels"]) == 3
            geometry = rows(next(run_dir.glob("geometry-*.csv")))
            assert geometry and all(float(row[key]) == value for row in geometry for key, value in
                [("present_source_width", 1920), ("present_source_height", 1080),
                 ("drawable_width", 1920), ("drawable_height", 1080)])
            display_paths = [path for path in run_dir.glob("display-*.csv")
                             if re.fullmatch(r"display-[0-9]+\.csv", path.name)]
            assert len(display_paths) == 1, display_paths
            display = rows(display_paths[0])
            assert sum(row["event"] == "presented" and row["presented_state"] == "valid" for row in display) >= count // 2
            cache_logs = list(run_dir.glob("pipeline-cache-*.jsonl"))
            cache_events = []
            for path in cache_logs:
                cache_events.extend(json.loads(line) for line in path.read_text().splitlines() if line.strip())
            if not enabled:
                assert not cache_logs, "Disabled cache created diagnostics."
            elif name != "cache_failure":
                assert cache_events, "Enabled cache did not report its operation."
            report["runs"][name] = dict(probe=probe, geometry=geometry, pipeline_cache_events=cache_events,
                pipeline_cache_enabled=enabled, prewarm_budget_ms=budget,
                pipeline_rows=rows(next(run_dir.glob("shaders-pipelines-*.csv"))))
            (folder / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            print(f"{name}: actual 1080p rendering and diagnostic capture passed", flush=True)
        validate_reuse_report(report)
        (folder / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(report["pipeline_reuse_assertions"], flush=True)
    finally:
        env = launch.build_environment("dxmt", ENGINE, PREFIX, profile="smooth60", source_build=True,
                                       pipeline_cache=False)
        subprocess.run([str(ENGINE / "bin/wineserver"), "-k"], env=env, timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([str(ENGINE / "bin/wineserver"), "-w"], env=env, timeout=30, check=True)
    print(folder, flush=True)


if __name__ == "__main__":
    main()
