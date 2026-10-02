#pragma once

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>

// Test-only observation/gating. Production never includes this file.
namespace ready_test {
inline std::atomic<unsigned> locks{0}, wait_entries{0};
inline std::atomic<bool> hold_registration{false};
inline std::condition_variable_any *active_cv = nullptr;
inline void reset() {
  locks = 0;
  wait_entries = 0;
  hold_registration = false;
}
}

namespace dxmt {
class mutex {
  std::mutex value_;
public:
  void lock() { ++ready_test::locks; value_.lock(); }
  void unlock() { value_.unlock(); }
  bool try_lock() { ++ready_test::locks; return value_.try_lock(); }
};

class condition_variable {
  std::condition_variable_any value_;
public:
  condition_variable() { ready_test::active_cv = &value_; }
  void notify_all() { value_.notify_all(); }
  template<class Predicate>
  void wait(std::unique_lock<mutex> &lock, Predicate predicate) {
    while (!predicate()) {
      ++ready_test::wait_entries;
      // Pause with the predicate mutex held: a producer must block until the
      // actual wait atomically releases it and registers its wakeup.
      while (ready_test::hold_registration.load()) std::this_thread::yield();
      value_.wait(lock);
    }
  }
};
}
