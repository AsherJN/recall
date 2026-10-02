#pragma once
#include "thread.hpp"
constexpr int THREAD_PRIORITY_NORMAL = 0;
constexpr int THREAD_PRIORITY_TIME_CRITICAL = 15;
inline int GetCurrentThread() { return 1; }
inline bool SetThreadPriority(int, int priority) {
  scheduler_test::assigned_priority = priority;
  scheduler_test::priority_calls.fetch_add(1);
  return true;
}
