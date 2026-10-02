#include <windows.h>
#include "d3d11_shader_trace.hpp"

extern "C" __declspec(dllexport) int trace_start() {
  auto &sink = dxmt::ShaderTraceSink::instance();
  sink.pipeline(1, 1, "graphics", "createMetal", 10, false);
  return sink.enabled();
}
extern "C" __declspec(dllexport) void trace_emit(unsigned id) {
  dxmt::ShaderTraceSink::instance().pipeline(1, id, "compute", "wait", 1100, true, 10000, 10031, 31);
}
extern "C" __declspec(dllexport) unsigned trace_stop() {
  const auto begin = GetTickCount64();
  dxmt::ShaderTraceSink::instance().shutdown();
  return static_cast<unsigned>(GetTickCount64() - begin);
}
