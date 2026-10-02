#pragma once
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace scheduler_test {
inline std::atomic_uint32_t hardware_threads{0};
inline std::atomic_uint32_t created_threads{0};
inline std::atomic_uint32_t alive_threads{0};
inline std::atomic_uint32_t priority_calls{0};
inline thread_local int assigned_priority = 999;
inline std::atomic_bool hold_worker_entry{false}, release_worker_entry{false};

// One-shot instrumentation exposes the predicate-to-wait gap while retaining
// the worker mutex. It lets a shutdown regression force the otherwise rare
// condition-variable notification race without relying on sleeps.
inline std::atomic_bool handoff_enabled{false}, handoff_entered{false};
inline std::atomic_bool handoff_ready{false}, handoff_release{false};
inline std::atomic_bool shutdown_lock_attempted{false}, early_notification{false};
inline std::atomic_bool handoff_wait_timed_out{false};
inline std::atomic<void *> handoff_mutex{nullptr}, handoff_condition{nullptr};
}

namespace dxmt {
class mutex {
  std::mutex mutex_;
public:
  void lock() {
    using namespace scheduler_test;
    if (handoff_ready.load() && !handoff_release.load() && handoff_mutex.load() == this)
      shutdown_lock_attempted.store(true);
    mutex_.lock();
  }
  void unlock() { mutex_.unlock(); }
};

class condition_variable {
  std::condition_variable_any condition_;
public:
  template <class Predicate>
  void wait(std::unique_lock<mutex> &lock, Predicate predicate) {
    using namespace scheduler_test;
    while (!predicate()) {
      if (handoff_enabled.load() && !handoff_entered.exchange(true)) {
        handoff_mutex.store(lock.mutex());
        handoff_condition.store(this);
        handoff_ready.store(true);
        handoff_release.wait(false);
        // Bound the deliberately lost-notify path so the old code can fail
        // the regression clearly instead of hanging the entire test process.
        if (condition_.wait_for(lock, std::chrono::seconds(1)) == std::cv_status::timeout)
          handoff_wait_timed_out.store(true);
      } else {
        condition_.wait(lock);
      }
    }
  }
  void notify_one() { condition_.notify_one(); }
  void notify_all() {
    using namespace scheduler_test;
    condition_.notify_all();
    if (handoff_ready.load() && !handoff_release.load() && handoff_condition.load() == this)
      early_notification.store(true);
  }
};
class thread {
  std::thread thread_;
public:
  template <class Function> explicit thread(Function &&function) {
    scheduler_test::created_threads.fetch_add(1);
    thread_ = std::thread([function = std::forward<Function>(function)]() mutable {
      scheduler_test::alive_threads.fetch_add(1);
      if (scheduler_test::hold_worker_entry.load())
        scheduler_test::release_worker_entry.wait(false);
      function();
      scheduler_test::alive_threads.fetch_sub(1);
    });
  }
  thread(thread &&) = default;
  thread &operator=(thread &&) = default;
  bool joinable() const { return thread_.joinable(); }
  void join() { thread_.join(); }
  static uint32_t hardware_concurrency() { return scheduler_test::hardware_threads.load(); }
};
}
