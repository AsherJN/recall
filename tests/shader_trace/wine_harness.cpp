#include <windows.h>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

static void require(bool condition, const char *message) {
  if (!condition) { std::fprintf(stderr, "FAIL %s (%lu)\n", message, GetLastError()); std::abort(); }
}
int main(int argc, char **argv) {
  require(argc == 3, "expected mode and test DLL");
  const auto library = LoadLibraryA(argv[2]);
  require(library != nullptr, "LoadLibrary");
  auto start = reinterpret_cast<int (*)()>(GetProcAddress(library, "trace_start"));
  auto emit = reinterpret_cast<void (*)(unsigned)>(GetProcAddress(library, "trace_emit"));
  auto stop = reinterpret_cast<unsigned (*)()>(GetProcAddress(library, "trace_stop"));
  require(start && emit && stop, "test DLL exports");
  const bool quiet = !std::strcmp(argv[1], "quiet");
  require(static_cast<bool>(start()) != quiet, "trace enabled state");
  if (quiet) {
    require(FreeLibrary(library), "quiet FreeLibrary");
    require(GetModuleHandleA("shader_trace_test.dll") == nullptr, "disabled tracing pinned DLL");
    std::puts("PASS quiet: no pin, DLL unloaded normally");
    return 0;
  }
  Sleep(800);
  if (!std::strcmp(argv[1], "abrupt")) {
    emit(2); // A sparse late record must flush without another threshold burst.
    Sleep(800);
    std::puts("PASS periodic sparse flush before abrupt TerminateProcess");
    std::fflush(stdout);
    TerminateProcess(GetCurrentProcess(), 0);
    return 99;
  }
  if (!std::strcmp(argv[1], "normal")) {
    std::puts("PASS normal ExitProcess without explicit shutdown");
    return 0;
  }
  require(!std::strcmp(argv[1], "unload"), "unknown mode");
  require(FreeLibrary(library), "active FreeLibrary");
  require(GetModuleHandleA("shader_trace_test.dll") == library, "active logger DLL not pinned");
  std::vector<std::thread> workers;
  for (unsigned worker = 0; worker < 4; ++worker) workers.emplace_back([&, worker] {
    for (unsigned item = 0; item < 20; ++item) { emit(2 + worker * 20 + item); Sleep(2); }
  });
  for (auto &worker : workers) worker.join();
  Sleep(600);
  const auto duration = stop();
  require(duration <= 650, "unbounded explicit shutdown");
  emit(999); // A late call remains mapped but admission must be closed.
  Sleep(300);
  require(stop() <= 650, "unbounded repeated shutdown");
  std::printf("PASS FreeLibrary pin, 80 concurrent late writes, shutdown %u ms, ignored post-shutdown write\n", duration);
  return 0;
}
