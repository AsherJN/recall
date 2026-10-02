#include "dxmt_tasks.hpp"
#include <array>
#include <deque>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>

namespace scheduler_test {
struct Task {
  uint64_t id;
  std::vector<Task *> dependencies;
  std::atomic_bool done{false};
  uint64_t value = 0;
  bool gated = false;
};
std::atomic_uint64_t active{0}, peak{0}, completed{0}, failures{0};
std::mutex gate_mutex;
std::condition_variable gate_condition;
bool gate_open = false;
int expected_priority = THREAD_PRIORITY_NORMAL;
}

namespace dxmt {
template <> struct task_trait<scheduler_test::Task *> {
  using Task = scheduler_test::Task;
  Task *run_task(Task *task) {
    using namespace scheduler_test;
    if (assigned_priority != expected_priority) failures.fetch_add(1);
    for (auto *dependency : task->dependencies) {
      if (!dependency->done.load()) return dependency;
    }
    auto count = active.fetch_add(1) + 1;
    auto previous = peak.load();
    while (previous < count && !peak.compare_exchange_weak(previous, count)) {}
    if (task->gated) {
      std::unique_lock lock(gate_mutex);
      gate_condition.wait(lock, [] { return gate_open; });
    }
    task->value = task->id + 1;
    for (auto *dependency : task->dependencies) task->value += dependency->value;
    std::this_thread::yield();
    active.fetch_sub(1);
    return task;
  }
  bool get_done(Task *task) { return task->done.load(); }
  void set_done(Task *task) {
    if (task->done.exchange(true)) scheduler_test::failures.fetch_add(1);
    scheduler_test::completed.fetch_add(1);
  }
};
}

void require(bool condition, const char *message) {
  if (!condition) throw std::runtime_error(message);
}

template <class Predicate>
void wait_for(Predicate predicate, const char *message) {
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!predicate()) {
    if (std::chrono::steady_clock::now() >= deadline) {
      std::cerr << "FAIL: " << message << std::endl;
      std::_Exit(1); // Avoid hanging shutdown if a bounded-worker test deadlocks.
    }
    std::this_thread::yield();
  }
}

void run_case(uint64_t requested, uint32_t hardware, uint64_t expected_cap, int priority) {
  using namespace scheduler_test;
  require(alive_threads.load() == 0, "previous scheduler must join workers");
  hardware_threads = hardware;
  created_threads = 0;
  priority_calls = 0;
  active = peak = completed = failures = 0;
  expected_priority = priority;
  gate_open = false;
  std::deque<Task> blockers;
  std::deque<Task> graph;
  constexpr uint64_t graph_count = 512;
  constexpr uint64_t queued_blockers = 48;
  for (uint64_t i = 0; i < expected_cap + queued_blockers; ++i) {
    blockers.emplace_back();
    blockers.back().id = i;
    blockers.back().gated = true;
  }
  for (uint64_t i = 0; i < graph_count; ++i) {
    graph.emplace_back();
    auto &task = graph.back();
    task.id = i;
    if (i > 0) task.dependencies.push_back(&graph[(i - 1) / 2]);
    if (i > 3) task.dependencies.push_back(&graph[i - 3]);
  }

  {
    dxmt::task_scheduler<Task *> scheduler(requested, priority);
    for (uint64_t i = 0; i < expected_cap; ++i) {
      scheduler.submit(&blockers[i]);
      wait_for([&] { return active.load() == i + 1; }, "pool should grow to configured capacity");
    }
    require(created_threads.load() == expected_cap, "pool must reach configured capacity");
    for (uint64_t i = expected_cap; i < blockers.size(); ++i) scheduler.submit(&blockers[i]);
    require(created_threads.load() == expected_cap, "queue pressure must not exceed worker cap");
    // Reverse submission gives blocked continuations and fan-out before roots.
    for (auto it = graph.rbegin(); it != graph.rend(); ++it) scheduler.submit(&*it);
    require(scheduler.get_running_threads() <= expected_cap, "reported concurrency exceeds cap");
    {
      std::lock_guard lock(gate_mutex);
      gate_open = true;
    }
    gate_condition.notify_all();
    wait_for([&] { return completed.load() == blockers.size() + graph.size(); }, "all dependencies and continuations must finish");
    require(peak.load() <= expected_cap, "actual task concurrency exceeds cap");
    require(failures.load() == 0, "duplicate completion or wrong priority");
    for (const auto &task : graph) {
      uint64_t expected_value = task.id + 1;
      for (auto *dependency : task.dependencies) expected_value += dependency->value;
      require(task.done.load() && task.value == expected_value, "dependency results must be available before dependent runs");
    }
    wait_for([&] { return scheduler.get_running_threads() == 0; }, "workers must become idle");
  }
  require(alive_threads.load() == 0, "destructor must join all workers");
  require(priority_calls.load() == created_threads.load(), "each worker must apply configured priority once");
  std::cout << "PASS: requested=" << requested << " hardware=" << hardware
            << " cap=" << expected_cap << " priority=" << priority
            << " completed=" << completed.load() << std::endl;
}

void test_shutdown_handoff() {
  using namespace scheduler_test;
  require(alive_threads.load() == 0, "shutdown test must start without workers");
  handoff_enabled = true;
  auto scheduler = std::make_unique<dxmt::task_scheduler<Task *>>(1, THREAD_PRIORITY_NORMAL);
  wait_for([] { return handoff_ready.load(); }, "worker must reach predicate-to-wait handoff");
  std::thread destroyer([&] { scheduler.reset(); });
  // With the fix, shutdown first tries to lock the worker mutex and blocks.
  // Without it, notify_all runs before the worker can start waiting. Both
  // paths publish an explicit handshake, so there is no scheduling guess.
  wait_for([] { return shutdown_lock_attempted.load() || early_notification.load(); },
           "shutdown must reach predicate synchronization or notification");
  handoff_release.store(true);
  handoff_release.notify_all();
  destroyer.join();
  handoff_enabled = false;
  require(!early_notification.load(), "shutdown notified before predicate-to-wait handoff: lost notification");
  require(!handoff_wait_timed_out.load(), "worker needed timeout recovery after missed shutdown notification");
  require(shutdown_lock_attempted.load(), "shutdown must lock the predicate mutex before notifying");
  require(alive_threads.load() == 0, "shutdown must join worker");
  std::cout << "PASS: deterministic predicate-to-wait shutdown handoff; notification cannot be lost.\n";
}

void test_cold_burst() {
  using namespace scheduler_test;
  require(alive_threads.load() == 0, "cold burst must start without workers");
  hold_worker_entry = true;
  release_worker_entry = false;
  gate_open = false;
  active = peak = completed = failures = 0;
  expected_priority = THREAD_PRIORITY_NORMAL;
  std::array<Task, 4> burst;
  {
    dxmt::task_scheduler<Task *> scheduler(4, THREAD_PRIORITY_NORMAL);
    // All requests arrive before any worker enters its loop. No later submit
    // can rescue an undersized pool; all four jobs must run concurrently.
    for (unsigned i = 0; i < burst.size(); ++i) {
      burst[i].id = i;
      burst[i].gated = true;
      scheduler.submit(&burst[i]);
    }
    release_worker_entry = true;
    release_worker_entry.notify_all();
    wait_for([] { return active.load() == 4; }, "cold burst must use all four configured workers without another submit");
    {
      std::lock_guard lock(gate_mutex);
      gate_open = true;
    }
    gate_condition.notify_all();
    wait_for([] { return completed.load() == 4; }, "cold burst must finish all jobs");
  }
  hold_worker_entry = false;
  require(alive_threads.load() == 0, "cold burst workers must join");
  require(peak.load() == 4 && failures.load() == 0, "cold burst concurrency and priority");
  std::cout << "PASS: four-job cold burst reaches configured concurrency without a later submit.\n";
}

int main(int argc, char **argv) try {
  if (argc == 2 && std::string(argv[1]) == "--burst-only") {
    test_cold_burst();
    return 0;
  }
  if (argc == 2 && std::string(argv[1]) == "--shutdown-only") {
    test_shutdown_handoff();
    return 0;
  }
  run_case(1, 10, 1, THREAD_PRIORITY_NORMAL);
  run_case(2, 10, 2, THREAD_PRIORITY_NORMAL);
  run_case(4, 10, 4, THREAD_PRIORITY_NORMAL);
  run_case(0, 0, 2, THREAD_PRIORITY_TIME_CRITICAL);
  run_case(0, 3, 6, THREAD_PRIORITY_TIME_CRITICAL);
  run_case(std::numeric_limits<uint64_t>::max(), 10, 64, THREAD_PRIORITY_NORMAL);
  test_cold_burst();
  test_shutdown_handoff();
  std::cout << "PASS: scheduler bounds, dependency progress, priority selection, automatic fallback, "
               "override clamp, and shutdown (ASan/UBSan).\n";
} catch (const std::exception &error) {
  std::cerr << "FAIL: " << error.what() << '\n';
  return 1;
}
