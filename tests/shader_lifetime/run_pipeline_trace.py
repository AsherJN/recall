#!/usr/bin/env python3
"""Run real pipeline wait/Metal-call scopes against deterministic host stubs."""
import argparse
import csv
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2] / "runtime/source/dxmt-ow2")
args = parser.parse_args()
directory = Path(__file__).resolve().parent
source_dir = args.source / "src/d3d11"


def block(source, start):
    start = source.index("{", start)
    depth, end = 1, start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


trace = (source_dir / "d3d11_shader_trace.hpp").read_text()
trace = "\n".join(line for line in trace.splitlines() if not line.startswith('#include "') and line != "#pragma once")
ready = (source_dir / "d3d11_pipeline_ready.hpp").read_text()
ready = "\n".join(line for line in ready.splitlines() if not line.startswith('#include "') and line != "#pragma once")
classes = []
for kind, filename, original, output in [
    ("graphics", "d3d11_pipeline.cpp", "MTLCompiledGraphicsPipelineImpl", "MTL_COMPILED_GRAPHICS_PIPELINE"),
    ("compute", "d3d11_pipeline.cpp", "MTLCompiledComputePipelineImpl", "MTL_COMPILED_COMPUTE_PIPELINE"),
    ("gs", "d3d11_pipeline_gs.cpp", "MTLCompiledGeometryPipelineImpl", "MTL_COMPILED_GRAPHICS_PIPELINE"),
    ("ts", "d3d11_pipeline_ts.cpp", "MTLCompiledTessellationPipelineImpl", "MTL_COMPILED_TESSELLATION_MESH_PIPELINE"),
]:
    source = (source_dir / filename).read_text()
    class_start = source.index("class " + original)
    get_body = block(source, source.index("void GetPipeline(", class_start))
    get_done = block(source, source.index("bool GetIsDone()", class_start))
    set_done = block(source, source.index("void SetIsDone(", class_start))
    metal_start = source.index(f'PipelineOperationTrace trace(trace_id_, "{kind}", false);', class_start)
    metal_body = block(source, source.rindex("{", class_start, metal_start))
    classes.append(f"""
struct Test_{kind} : Fixture {{
  void GetPipeline({output} *pPipeline) {get_body}
  bool GetIsDone() {get_done}
  void SetIsDone(bool state) {set_done}
  void create() {{ int info = 0, err = 0; {metal_body} }}
  using Output = {output};
}};
""")
harness = ((directory / "pipeline_trace.cpp.in").read_text().replace("@SHADER_TRACE@", trace)
           .replace("@PIPELINE_READY@", ready).replace("@PIPELINE_CLASSES@", "\n".join(classes)))
with tempfile.TemporaryDirectory(prefix="pipeline-trace-", dir=directory) as temporary:
    temporary = Path(temporary)
    cpp, executable = temporary / "test.cpp", temporary / "test"
    cpp.write_text(harness)
    subprocess.run(["/usr/bin/clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror", "-pthread",
                    "-fsanitize=address,undefined", "-fno-omit-frame-pointer", str(cpp), "-o", str(executable)], check=True)
    for mode in ["pipelines", "cap", "shutdown", "disabled"]:
        prefix = temporary / mode
        environment = dict(os.environ, DXMT_SHADER_LOG=str(prefix))
        if mode == "disabled":
            environment.pop("DXMT_SHADER_LOG")
        subprocess.run([str(executable), mode], check=True, env=environment, timeout=20)
        if mode == "disabled":
            assert not list(temporary.glob("disabled*"))
            print("PASS disabled: four actual pipeline methods, no trace files or publication timestamps")
            continue
        with Path(str(prefix) + "-pipelines-42.csv").open() as stream:
            rows = list(csv.DictReader(stream))
        with Path(str(prefix) + "-summary-42.csv").open() as stream:
            summary = {row["stream"]: row for row in csv.DictReader(stream)}
        assert len(rows) == int(summary["pipeline"]["records"])
        if mode == "pipelines":
            assert len(rows) + int(summary["pipeline"]["dropped"]) == 16, summary
            for kind in ["graphics", "compute", "gs", "ts"]:
                waits = [row for row in rows if row["type"] == kind and row["phase"] == "wait"]
                creates = [row for row in rows if row["type"] == kind and row["phase"] == "createMetal"]
                assert 1 <= len(waits) <= 2 and 1 <= len(creates) <= 2
                for row in waits:
                    assert int(row["duration_us"]) > 100
                    published = int(row["ready_published_monotonic_us"])
                    returned = int(row["wait_return_monotonic_us"])
                    assert published > 0 and returned >= published
                    assert int(row["ready_to_return_us"]) == returned - published
                for row in creates:
                    assert all(int(row[column]) == 0 for column in
                               ("ready_published_monotonic_us", "wait_return_monotonic_us", "ready_to_return_us"))
            assert int(summary["pipeline"]["wait_samples"]) == 9  # Eight actual waits plus suppressed fixture.
            assert int(summary["pipeline"]["create_samples"]) == 8
        elif mode == "cap":
            for stream in ("pipeline", "shader"):
                assert 0 < int(summary[stream]["records"]) <= 100000
                assert int(summary[stream]["records"]) + int(summary[stream]["dropped"]) == 100005
                assert int(summary[stream]["dropped_limit"]) == 5
                assert int(summary[stream]["pending"]) == 0
        else:
            assert 1 <= len(rows) <= 4001
        print(f"PASS {mode}: actual scopes, bounded rows/aggregate accounting and safe shutdown")
