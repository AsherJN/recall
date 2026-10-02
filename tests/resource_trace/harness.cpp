#include "dxmt_resource_log.hpp"
#include <iostream>
#include <vector>
#include <sys/stat.h>

using dxmt::ResourceTelemetry;
using dxmt::ResourceScope;
// Constructed before the function-static logger; destroyed after its cleanup.
struct LateStaticResource {
  ~LateStaticResource() { ResourceScope span(ResourceTelemetry::TextureRelease); }
} late_static_resource;
struct ReleasedObject {
  ~ReleasedObject() { std::this_thread::sleep_for(std::chrono::milliseconds(4)); }
  void free() {
    ResourceScope span(ResourceTelemetry::BufferRelease, this, 4096);
    delete this; // Includes the real destructor; ASan checks scope's exit for UAF.
  }
};
int main(int argc, char **argv) {
  if (argc != 3) return 2;
  std::string mode = argv[2];
  std::string prefix = std::string(argv[1]) + "-" + std::to_string(getpid()) + "-" +
    std::to_string(reinterpret_cast<uintptr_t>(&ResourceTelemetry::get));
  if (mode == "disabled") unsetenv("DXMT_RESOURCE_LOG");
  else setenv("DXMT_RESOURCE_LOG", argv[1], 1);
  if (mode == "blocked" && mkfifo((prefix + ".totals.csv").c_str(), 0600)) return 3;
  auto *trace = ResourceTelemetry::get();
  if (mode == "disabled" && trace) return 4;
  if (mode == "normal") {
    for (int i = 0; i < 5000; ++i) {
      ResourceScope span(ResourceTelemetry::BufferUpload, nullptr, 256);
    }
    { ResourceScope outer(ResourceTelemetry::ReleaseBatch); outer.units(1); (new ReleasedObject)->free(); }
    { ResourceScope once(ResourceTelemetry::MapImmediate, nullptr, 128, 4); once.finish(); }
  } else if (mode == "concurrent" || mode == "rotation") {
    std::vector<std::thread> threads;
    for (int t = 0; t < (mode == "rotation" ? 8 : 80); ++t) threads.emplace_back([&, t] {
      for (int block = 0; block < 10; ++block) {
        for (int i = 0; i < 100; ++i) {
          auto end = ResourceTelemetry::now();
          trace->record(ResourceTelemetry::BufferAllocate, end - (mode == "rotation" ? 3000000 : 500), end, t, 1024, 1, 0);
        }
        if (mode == "rotation") std::this_thread::sleep_for(std::chrono::milliseconds(120));
      }
    });
    for (auto &thread : threads) thread.join();
  } else if (mode == "bench" || mode == "disabled") {
    constexpr unsigned count = 1000000;
    auto start = ResourceTelemetry::now();
    for (unsigned i = 0; i < count; ++i) {
      ResourceScope span(ResourceTelemetry::MapImmediate, nullptr, 256);
      std::atomic_signal_fence(std::memory_order_seq_cst);
    }
    std::cout << "ns_per_scope=" << double(ResourceTelemetry::now() - start) / count << '\n';
  } else if (mode == "missing" || mode == "blocked") {
    for (unsigned i = 0; i < 10000; ++i) {
      ResourceScope span(ResourceTelemetry::MapImmediate);
    }
  } else return 5;
  std::cout << prefix << '\n';
}
