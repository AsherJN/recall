#include <windows.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <iostream>
#include <thread>
#include <vector>

// This include resolves thread.hpp to the production src/util implementation,
// including SRW locks and SleepConditionVariableSRW. No test stubs are used.
#include "d3d11_pipeline_ready.hpp"

using Clock = std::chrono::steady_clock;
static int64_t ns() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch()).count();
}
static void require(bool condition, const char *message) {
  if (!condition) { std::fprintf(stderr, "FAIL %s\n", message); std::abort(); }
}

static void correctness() {
  dxmt::PipelineReady ready;
  require(!ready.isReady(), "new completion ready");
  ready.publish(true);
  const auto timestamp = ready.wait();
  require(timestamp > 0, "missing publication timestamp");
  for (unsigned i = 0; i < 100000; ++i)
    require(ready.wait() == timestamp && ready.isReady(), "ready result changed");
  ready.publish();
  require(ready.wait() == timestamp, "duplicate publish changed timestamp");

  for (unsigned repetition = 0; repetition < 100; ++repetition) {
    dxmt::PipelineReady completion;
    uint64_t payload[8]{};
    const void *pipeline = nullptr;
    int error = 0;
    std::atomic<unsigned> entering{0}, correct{0};
    std::vector<std::thread> waiters;
    const bool failure = repetition % 2;
    for (unsigned i = 0; i < 8; ++i) waiters.emplace_back([&] {
      ++entering;
      const auto published = completion.wait();
      bool valid = published > 0;
      for (unsigned j = 0; j < 8; ++j) valid &= payload[j] == repetition + j + 123;
      valid &= failure ? pipeline == nullptr && error == -1 : pipeline == &payload && error == 0;
      if (valid) ++correct;
    });
    while (entering != 8) SwitchToThread();
    if (repetition % 3 == 0) Sleep(1);
    for (unsigned j = 0; j < 8; ++j) payload[j] = repetition + j + 123;
    pipeline = failure ? nullptr : &payload;
    error = failure ? -1 : 0;
    completion.publish(true);
    for (auto &waiter : waiters) waiter.join();
    require(correct == 8, "Windows multiwaiter visibility or failure completion");
  }
  std::fprintf(stderr, "PASS production Windows helper: ready path, 800 waiter releases, payload visibility, failed/null result, duplicate publication\n");
}

static void sample(bool replacement, unsigned delay, unsigned iteration, unsigned order) {
  dxmt::PipelineReady completion;
  std::atomic_bool old_ready{false}, entering{false};
  int64_t before = 0, after = 0;
  uint64_t payload = 0;
  std::thread producer([&] {
    while (!entering.load(std::memory_order_acquire)) SwitchToThread();
    if (delay) Sleep(delay);
    payload = 0x123456789abcdef0ULL;
    before = ns();
    if (replacement) completion.publish(true);
    else {
      old_ready.store(true, std::memory_order_release);
      old_ready.notify_all();
    }
    after = ns();
  });
  entering.store(true, std::memory_order_release);
  uint64_t published_us = 0;
  if (replacement) published_us = completion.wait();
  else old_ready.wait(false, std::memory_order_acquire);
  const auto returned = ns();
  require(payload == 0x123456789abcdef0ULL, "wait returned before payload publication");
  producer.join();
  require(returned >= before, "invalid signal-to-return measurement");
  std::printf("%s,%u,%u,%u,%lld,%lld,%lld,%llu,%.3f,%.3f,%.3f\n",
      replacement ? "pipeline_ready_srw_cv" : "std_atomic_wait", delay, iteration, order,
      static_cast<long long>(before), static_cast<long long>(after), static_cast<long long>(returned),
      static_cast<unsigned long long>(published_us), (returned - before) / 1000., (after - before) / 1000.,
      published_us ? returned / 1000. - published_us : 0.);
}

int main() {
  correctness();
  std::puts("mechanism,ready_delay_ms,iteration,order,signal_start_ns,signal_end_ns,wait_return_ns,ready_published_us,signal_to_return_us,signal_call_us,publication_to_return_us");
  for (unsigned iteration = 0; iteration < 12; ++iteration) {
    for (unsigned delay : {0, 1, 5, 20, 40, 80, 120, 160}) {
      // Alternate A/B order every repeat and delay: avoid sequential batches.
      const bool first_new = (iteration + delay) % 2;
      sample(first_new, delay, iteration, 0);
      sample(!first_new, delay, iteration, 1);
    }
  }
  std::fflush(stdout);
  return 0;
}
