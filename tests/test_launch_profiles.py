import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import launch_cx26 as launch
import measure_resources as resources
import stage_dxmt_local as stage


class LaunchProfiles(unittest.TestCase):
    def test_smooth_profile_is_quiet_and_enables_msync(self):
        engine = ROOT / "runtime/soju-engine-dxmt-ow2-v0.2"
        prefix = ROOT / "runtime/prefix-dxmt-ow2-v0.2"
        with patch.dict(os.environ, {"DXMT_CONFIG": "stale", "DXMT_GEOMETRY_LOG": "stale",
                                     "MTL_HUD_ENABLED": "1",
                                     "MTL_SHADER_VALIDATION": "1", "WINEESYNC": "1"}):
            env = launch.build_environment("dxmt", engine, prefix, profile="smooth60")
        self.assertEqual(env["WINEMSYNC"], "1")
        self.assertEqual(env["WINEESYNC"], "0")
        self.assertEqual(env["DXMT_LOG_LEVEL"], "error")
        self.assertEqual(env["DXMT_LOG_PATH"], "none")
        self.assertTrue(env["DXMT_CONFIG_FILE"].endswith("dxmt-smooth60.conf"))
        self.assertTrue(env["WINEDLLOVERRIDES"].endswith(";d3d12="))
        for key in ["DXMT_CONFIG", "DXMT_FRAME_LOG", "DXMT_GEOMETRY_LOG", "MTL_HUD_ENABLED", "MTL_SHADER_VALIDATION"]:
            self.assertNotIn(key, env)
        self.assertIn("CX_APPLEGPTK_LIBD3DSHARED_PATH", env)

    def test_d3dmetal_has_no_dxmt_state(self):
        with patch.dict(os.environ, {"DXMT_CONFIG": "stale", "DXMT_FRAME_LOG": "stale",
                                     "DXMT_GEOMETRY_LOG": "stale",
                                     "WINEDLLOVERRIDES": "d3d12="}):
            env = launch.build_environment("d3dmetal", launch.ENGINE, launch.PREFIX)
        self.assertFalse(any(k.startswith("DXMT_") for k in env))
        self.assertNotIn("WINEDLLOVERRIDES", env)
        self.assertIn("CX_APPLEGPTK_LIBD3DSHARED_PATH", env)

    def test_pipeline_reuse_is_isolated_and_can_be_disabled(self):
        engine = ROOT / "runtime/soju-engine-dxmt-local"
        prefix = ROOT / "runtime/prefix-dxmt-local"
        inherited = {"DXMT_PIPELINE_CACHE_PATH": "/stale-cache", "DXMT_PIPELINE_CACHE_LOG": "/stale-log"}
        with patch.dict(os.environ, inherited):
            for source, profile, enabled in ((False, "smooth60", True), (True, "baseline", True),
                                             (True, "smooth60", False)):
                env = launch.build_environment("dxmt", engine, prefix, source_build=source,
                                               profile=profile, pipeline_cache=enabled)
                self.assertFalse(any(k.startswith("DXMT_PIPELINE_CACHE_") for k in env))
            quiet = launch.build_environment("dxmt", engine, prefix, source_build=True, profile="smooth60")
            learn = launch.build_environment("dxmt", engine, prefix, source_build=True,
                                             profile="smooth60", pipeline_prewarm=False)
        self.assertEqual(quiet["DXMT_PIPELINE_CACHE_PATH"], str(ROOT / "runtime/dxmt-pipeline-cache-source"))
        self.assertEqual(quiet["DXMT_PIPELINE_CACHE_PREWARM_MS"], "10000")
        self.assertEqual(quiet["DXMT_PIPELINE_CACHE_PREFER_EXPENSIVE"], "1")
        self.assertNotIn("DXMT_PIPELINE_CACHE_LOG", quiet)
        self.assertEqual(learn["DXMT_PIPELINE_CACHE_PREWARM_MS"], "0")

    def test_measurement_has_frame_capture_without_heavy_diagnostics(self):
        engine = ROOT / "runtime/soju-engine-dxmt-local"
        prefix = ROOT / "runtime/prefix-dxmt-local"
        inherited = {"DXMT_FRAME_LOG": "stale", "DXMT_LOG_PATH": "stale",
                     "DXMT_RESOURCE_LOG": "stale",
                     "DXMT_SHADER_LOG": "stale", "DXMT_DISPLAY_LOG": "stale",
                     "MTL_HUD_ENABLED": "1", "MTL_HUD_LOG_SHADER_ENABLED": "1",
                     "MTL_SHADER_VALIDATION": "1", "MTL_CAPTURE_ENABLED": "1",
                     "MTL_DEBUG_LAYER": "1", "WINEDEBUG": "+all"}
        with patch.dict(os.environ, inherited):
            env = launch.build_environment("dxmt", engine, prefix, profile="smooth60",
                                           source_build=True, measure=True, stamp="unit-test")
        self.assertTrue(env["DXMT_FRAME_LOG"].endswith(r"measured-unit-test\frames"))
        self.assertNotIn("DXMT_RESOURCE_LOG", env)
        self.assertTrue(env["DXMT_GEOMETRY_LOG"].endswith(r"measured-unit-test\geometry"))
        self.assertTrue(env["DXMT_WINDOW_LOG"].endswith(r"measured-unit-test\windows"))
        self.assertTrue(env["DXMT_SHADER_LOG"].endswith(r"measured-unit-test\shaders"))
        self.assertEqual(env["DXMT_DISPLAY_LOG"], str(ROOT / "logs/dxmt/measured-unit-test/display"))
        self.assertEqual(env["DXMT_PIPELINE_CACHE_LOG"], str(ROOT / "logs/dxmt/measured-unit-test/pipeline-cache"))
        self.assertTrue(env["DXMT_CONFIG_FILE"].endswith("dxmt-source60.conf"))
        self.assertEqual(env["DXMT_LOG_LEVEL"], "error")
        self.assertEqual(env["DXMT_LOG_PATH"], "none")
        self.assertEqual(env["WINEDEBUG"], "-all")
        self.assertEqual(env["WINEMSYNC"], "1")
        self.assertFalse(any(key.startswith("MTL_HUD_") for key in env))
        for key in ("MTL_SHADER_VALIDATION", "MTL_CAPTURE_ENABLED", "MTL_DEBUG_LAYER"):
            self.assertNotIn(key, env)

    def test_deep_resource_tracing_is_explicit_and_requires_measurement(self):
        engine = ROOT / "runtime/soju-engine-dxmt-local"
        prefix = ROOT / "runtime/prefix-dxmt-local"
        env = launch.build_environment("dxmt", engine, prefix, source_build=True,
                                       measure=True, trace_resources=True, stamp="diagnostic")
        self.assertTrue(env["DXMT_RESOURCE_LOG"].endswith(r"measured-diagnostic\resource-ops"))
        with self.assertRaises(ValueError):
            launch.build_environment("dxmt", engine, prefix, trace_resources=True)

    def test_measurement_requires_source_dxmt_and_excludes_full_diagnostics(self):
        for backend, source, performance in (("d3dmetal", True, False),
                                              ("dxmt", False, False),
                                              ("dxmt", True, True)):
            with self.subTest(backend=backend, source=source, performance=performance):
                with self.assertRaises(ValueError):
                    launch.build_environment(backend, launch.ENGINE, launch.PREFIX,
                                             source_build=source, performance=performance,
                                             measure=True, stamp="unit-test")

    def test_full_performance_mode_preserves_hud_and_logging(self):
        env = launch.build_environment("dxmt", ROOT / "runtime/soju-engine-dxmt-local",
                                       ROOT / "runtime/prefix-dxmt-local", performance=True,
                                       source_build=True, stamp="unit-test")
        self.assertEqual(env["MTL_HUD_ENABLED"], "1")
        self.assertEqual(env["MTL_HUD_LOG_SHADER_ENABLED"], "1")
        self.assertEqual(env["WINEDEBUG"], "-all,err+all")
        self.assertIn("DXMT_FRAME_LOG", env)
        self.assertNotEqual(env["DXMT_LOG_PATH"], "none")

    def test_resource_capture_excludes_game_from_other_engine(self):
        def command(*args):
            if args[0] == "vm_stat":
                return 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nSwapouts: 0.\n'
            if args[0] == "ps":
                return ('100 00:05 20.0 2048 Fri Sep 11 20:00:00 2026 C:\\Overwatch.exe\n'
                        '200 00:05 30.0 3072 Fri Sep 11 20:01:00 2026 C:\\Overwatch.exe\n')
            if args[0] == "lsof":
                engine = "soju-engine-v1.5" if args[args.index("-p") + 1] == "100" else "soju-engine-dxmt-local"
                return str(ROOT / "runtime" / engine / "bin/wine")
            if args[0] == "sysctl":
                return 'used = 0.00M'
            if args[:3] == ("pmset", "-g", "therm"):
                return 'CPU_Speed_Limit \t= 100\nCPU_Available_CPUs \t= 10\n'
            raise AssertionError(args)
        with patch.object(resources, "command", side_effect=command), \
             patch.object(resources, "gpu_statistics", return_value={}):
            record = resources.sample("soju-engine-dxmt-local")
        self.assertEqual([game["pid"] for game in record["games"]], [200])
        self.assertEqual(record["thermal"], dict(cpu_speed_limit_percent=100, cpu_available_cpus=10))
        self.assertEqual(record["client_processes"], [])

    def test_resource_collector_is_bounded_detached_and_engine_scoped(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = dict(frame_prefix=Path(tmp) / "frames", resources=Path(tmp) / "resources.jsonl",
                         collector_log=Path(tmp) / "collector.log")
            with patch.object(launch.subprocess, "Popen") as popen:
                popen.return_value.pid = 12345
                metadata = launch.start_resource_capture(
                    ROOT / "runtime/soju-engine-dxmt-local", paths)
            args = popen.call_args.args[0]
            kwargs = popen.call_args.kwargs
            self.assertEqual(args[args.index("--seconds") + 1], "900")
            self.assertEqual(args[args.index("--wait-for-game") + 1], "600")
            self.assertEqual(args[args.index("--engine") + 1], "soju-engine-dxmt-local")
            self.assertEqual(args[args.index("--output") + 1], str(paths["resources"]))
            self.assertTrue(kwargs["start_new_session"])
            self.assertEqual(kwargs["stdin"], launch.subprocess.DEVNULL)
            self.assertEqual(metadata["collector_pid"], 12345)
            self.assertNotIn("env", metadata)
            self.assertNotIn("--hitch-stacks", args)

    def test_stack_sampling_requires_explicit_opt_in(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = dict(resources=Path(tmp) / "resources.jsonl", collector_log=Path(tmp) / "collector.log")
            with patch.object(launch.subprocess, "Popen") as popen:
                popen.return_value.pid = 12345
                launch.start_resource_capture(ROOT / "runtime/soju-engine-dxmt-local", paths,
                                              hitch_stacks=True)
            self.assertIn("--hitch-stacks", popen.call_args.args[0])

    def test_gpu_capture_only_uses_allowlisted_statistics(self):
        output = ('"IOReportLegend" = {"Device Utilization %"=99,"private"="discard"}\n'
                  '"PerformanceStatistics" = {"Device Utilization %"=42,'
                  '"Renderer Utilization %"=38,"In use system memory"=123456,"private"="discard"}\n')
        with patch.object(resources, "command", return_value=output):
            stats = resources.gpu_statistics()
        self.assertEqual(stats, {"device_utilization_percent": 42,
                                 "renderer_utilization_percent": 38,
                                 "in_use_memory_bytes": 123456})
        with patch.object(resources, "command", side_effect=OSError):
            self.assertEqual(resources.gpu_statistics(), {})

    def test_running_game_prevents_every_stop(self):
        with patch.object(launch.subprocess, "check_output", return_value="C:\\Overwatch.exe\n"), \
             patch.object(launch.subprocess, "run") as run:
            with self.assertRaises(SystemExit):
                launch.stop_clients()
            run.assert_not_called()

    def test_bad_build_hash_refuses_before_environment_changes(self):
        import json
        with tempfile.TemporaryDirectory(dir=ROOT / "runtime/diagnostics") as tmp:
            path = Path(tmp)
            (path / "build-manifest.json").write_text(json.dumps({"files": {}}))
            with patch.object(stage, "INSTALL", path), patch.object(stage, "stop_clients") as stop:
                with self.assertRaises(SystemExit):
                    stage.validate_build()
                stop.assert_not_called()


if __name__ == "__main__":
    unittest.main()
