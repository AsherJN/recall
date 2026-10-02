#include "d3d11_pipeline_ready.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <thread>
#include <type_traits>
#include <vector>

using dxmt::PipelineReady;
using namespace std::chrono_literals;

static void check(bool condition, const char *message) {
  if (!condition) throw std::runtime_error(message);
}
template<class Predicate> static void eventually(Predicate predicate) {
  const auto end = std::chrono::steady_clock::now() + 3s;
  while (!predicate()) {
    if (std::chrono::steady_clock::now() > end) std::terminate();
    std::this_thread::yield();
  }
}
struct Payload {
  uint64_t words[32]{};
  const void *pipeline = nullptr;
  int error = 0;
};

static void early_completion_and_fast_path() {
  static_assert(!std::is_copy_constructible_v<PipelineReady>);
  static_assert(!std::is_move_constructible_v<PipelineReady>);
  ready_test::reset();
  PipelineReady ready;
  check(!ready.isReady(), "new completion already ready");
  ready.publish(true);
  const auto published = ready.wait();
  check(published > 0, "timed publication lost timestamp");
  ready_test::reset();
  for (unsigned i = 0; i < 100000; ++i) {
    check(ready.isReady() && ready.wait() == published, "ready fast path changed result");
  }
  check(ready_test::locks == 0 && ready_test::wait_entries == 0,
        "ready fast path acquired a mutex or waited");
  ready.publish(false);
  check(ready.wait() == published, "duplicate publication changed timestamp");
  PipelineReady untimed;
  untimed.publish();
  check(untimed.wait() == 0 && untimed.isReady(), "untimed completion created timing overhead");
}

static void publication_at_wait_registration() {
  ready_test::reset();
  PipelineReady ready;
  Payload payload;
  ready_test::hold_registration = true;
  std::atomic<bool> publishing{false}, published{false}, returned{false};
  std::thread waiter([&] {
    const auto stamp = ready.wait();
    check(stamp > 0 && payload.words[7] == 0xfeedbeef, "registration race lost publication data");
    returned = true;
  });
  eventually([] { return ready_test::wait_entries == 1; });
  std::thread producer([&] {
    payload.words[7] = 0xfeedbeef;
    publishing = true;
    ready.publish(true);
    published = true;
  });
  eventually([&] { return publishing.load() && ready_test::locks >= 2; });
  std::this_thread::sleep_for(2ms);
  check(!published && !returned, "publisher bypassed the predicate mutex");
  ready_test::hold_registration = false;
  eventually([&] { return returned.load(); });
  producer.join();
  waiter.join();
}

static void spurious_notifications() {
  ready_test::reset();
  PipelineReady ready;
  std::atomic<bool> returned{false};
  std::thread waiter([&] { ready.wait(); returned = true; });
  eventually([] { return ready_test::wait_entries > 0; });
  for (unsigned i = 0; i < 20; ++i) {
    ready_test::active_cv->notify_all();
    std::this_thread::sleep_for(1ms);
  }
  check(ready_test::wait_entries > 1 && !returned, "spurious wake escaped predicate wait");
  ready.publish();
  waiter.join();
  check(returned, "real publication did not release waiter");
}

static void multiple_waiters_and_failure() {
  for (bool fail : {false, true}) {
    ready_test::reset();
    auto ready = std::make_unique<PipelineReady>();
    Payload payload;
    std::atomic<unsigned> correct{0};
    std::vector<std::thread> waiters;
    for (unsigned i = 0; i < 12; ++i) waiters.emplace_back([&] {
      const auto timestamp = ready->wait();
      bool valid = timestamp > 0;
      for (unsigned j = 0; j < 32; ++j) valid &= payload.words[j] == 0x12345678ULL + j;
      valid &= fail ? payload.pipeline == nullptr && payload.error == -7
                    : payload.pipeline == &payload && payload.error == 0;
      if (valid) ++correct;
    });
    eventually([] { return ready_test::wait_entries == 12; });
    for (unsigned j = 0; j < 32; ++j) payload.words[j] = 0x12345678ULL + j;
    payload.pipeline = fail ? nullptr : &payload;
    payload.error = fail ? -7 : 0;
    ready->publish(true);
    for (auto &thread : waiters) thread.join();
    check(correct == 12, "multiwaiter lost successful or failed result publication");
    ready.reset(); // Destruction is valid once the owner has joined all waiters.
  }
}

static void publication_races() {
  for (unsigned iteration = 0; iteration < 1200; ++iteration) {
    PipelineReady ready;
    uint64_t payload = 0;
    std::atomic<bool> start{false};
    std::thread waiter([&] {
      while (!start.load(std::memory_order_relaxed)) std::this_thread::yield();
      ready.wait();
      check(payload == iteration + 1, "raced acquire observed incomplete payload");
    });
    start.store(true, std::memory_order_relaxed);
    if (iteration % 3 == 0) std::this_thread::yield();
    payload = iteration + 1;
    ready.publish(iteration % 2);
    waiter.join();
  }
}

int main() {
  try {
    early_completion_and_fast_path();
    publication_at_wait_registration();
    spurious_notifications();
    multiple_waiters_and_failure();
    publication_races();
    std::cout << "PASS actual PipelineReady: early completion, lock-free ready path, wait-registration race, spurious wakes, 12 waiters, failure/null payload, 1200 publication races, joined lifetime\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
}
