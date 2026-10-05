#!/usr/bin/env python3
"""Run deterministic macOS source tests without a game/runtime installation.

The omitted integration modules need installed engine files, upstream source,
historical desktop shortcuts, or private measured sessions. No fake runtime
files are installed to make those prerequisites appear satisfied.
"""
from pathlib import Path
import sys
import subprocess
import unittest

PORTABLE_MODULES = (
    'test_measurement_markers', 'test_resource_ops', 'test_resource_sessions',
    'test_windowed_preferences', 'test_prepare_dxmt_pipelines',
    'test_summarize_frames', 'test_process_probe', 'test_summarize_display',
    'test_v1_finish', 'test_derive_runtime', 'test_pipeline_helper',
)


if __name__ == '__main__':
    # The native counter reader is source-built, never copied from an installed
    # development runtime. Build failure must stop the fresh-checkout check.
    subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] /
                                      'scripts/process_probe.py'), '--build'], check=True)
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    suite = unittest.defaultTestLoader.loadTestsFromNames(PORTABLE_MODULES)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
