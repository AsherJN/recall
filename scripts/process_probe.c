/* Read-only, out-of-process counters. No task ports, memory scans or suspension. */
#include <errno.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

/* A flat uint64 ABI avoids copying SDK struct layouts into Python. */
#define FIELDS(X) \
 X(unix_us) X(monotonic_ns) X(query_duration_ns) X(start_abstime) \
 X(user_ns) X(system_ns) X(resident_bytes) X(footprint_bytes) X(wired_bytes) \
 X(pageins) X(disk_read_bytes) X(disk_write_bytes) X(runnable_ns) \
 X(faults_u32) X(cow_faults_u32) X(context_switches_u32) \
 X(mach_calls_u32) X(unix_calls_u32) X(threads) X(running_threads) X(task_counter_saturated) \
 X(vm_error) X(vm_page_bytes) X(vm_compressions) X(vm_decompressions) \
 X(vm_swapins) X(vm_swapouts) X(vm_compressor_pages) X(vm_free_pages) \
 X(cpu_error) X(cpu_user_ticks_u32) X(cpu_system_ticks_u32) \
 X(cpu_idle_ticks_u32) X(cpu_nice_ticks_u32)
#define ENUM(name) name,
enum { FIELDS(ENUM) FIELD_COUNT };
#undef ENUM
#define NAME(name) #name ","
const char *ow_probe_fields(void) { return FIELDS(NAME); }
#undef NAME

int ow_probe_sample(int pid, uint64_t expected_start, uint64_t *out, uint32_t count) {
  if (!out || count != FIELD_COUNT || pid <= 0) return EINVAL;
  memset(out, 0, count * sizeof(*out));
  /* Same awake-time clock as Python time.monotonic_ns / mach_absolute_time. */
  uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  struct timespec utc;
  clock_gettime(CLOCK_REALTIME, &utc);
  out[unix_us] = (uint64_t)utc.tv_sec * 1000000 + utc.tv_nsec / 1000;
  out[monotonic_ns] = began;
  struct rusage_info_v4 usage, after;
  struct proc_taskinfo task;
  if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage)) return errno ?: EIO;
  if (expected_start && usage.ri_proc_start_abstime != expected_start) return ESTALE;
  if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) != sizeof(task)) return errno ?: EIO;
  if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&after)) return errno ?: EIO;
  if (usage.ri_proc_start_abstime != after.ri_proc_start_abstime) return ESTALE;
  out[start_abstime] = usage.ri_proc_start_abstime;
  /* XNU fill_task_rusage exports Mach ticks (not ns on Apple Silicon). */
  mach_timebase_info_data_t tb;
  if (mach_timebase_info(&tb) != KERN_SUCCESS || !tb.denom) return EIO;
  out[user_ns] = (__uint128_t)usage.ri_user_time * tb.numer / tb.denom;
  out[system_ns] = (__uint128_t)usage.ri_system_time * tb.numer / tb.denom;
  out[resident_bytes] = usage.ri_resident_size;
  out[footprint_bytes] = usage.ri_phys_footprint;
  out[wired_bytes] = usage.ri_wired_size;
  out[pageins] = usage.ri_pageins;
  out[disk_read_bytes] = usage.ri_diskio_bytesread;
  out[disk_write_bytes] = usage.ri_diskio_byteswritten;
  /* Includes time executing; summed across threads, not main-thread wait time. */
  out[runnable_ns] = (__uint128_t)usage.ri_runnable_time * tb.numer / tb.denom;
  out[faults_u32] = (uint32_t)task.pti_faults;
  out[cow_faults_u32] = (uint32_t)task.pti_cow_faults;
  out[context_switches_u32] = (uint32_t)task.pti_csw;
  out[mach_calls_u32] = (uint32_t)task.pti_syscalls_mach;
  out[unix_calls_u32] = (uint32_t)task.pti_syscalls_unix;
  out[threads] = task.pti_threadnum;
  out[running_threads] = task.pti_numrunning;
  out[task_counter_saturated] = task.pti_faults == INT32_MAX || task.pti_cow_faults == INT32_MAX ||
      task.pti_csw == INT32_MAX || task.pti_syscalls_mach == INT32_MAX || task.pti_syscalls_unix == INT32_MAX;

  mach_port_t host = mach_host_self();
  vm_statistics64_data_t vm;
  mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
  out[vm_error] = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &n);
  if (!out[vm_error]) {
    out[vm_page_bytes] = vm_kernel_page_size;
    out[vm_compressions] = vm.compressions;
    out[vm_decompressions] = vm.decompressions;
    out[vm_swapins] = vm.swapins;
    out[vm_swapouts] = vm.swapouts;
    out[vm_compressor_pages] = vm.compressor_page_count;
    out[vm_free_pages] = vm.free_count;
  }
  host_cpu_load_info_data_t cpu;
  n = HOST_CPU_LOAD_INFO_COUNT;
  out[cpu_error] = host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &n);
  if (!out[cpu_error]) {
    out[cpu_user_ticks_u32] = cpu.cpu_ticks[CPU_STATE_USER];
    out[cpu_system_ticks_u32] = cpu.cpu_ticks[CPU_STATE_SYSTEM];
    out[cpu_idle_ticks_u32] = cpu.cpu_ticks[CPU_STATE_IDLE];
    out[cpu_nice_ticks_u32] = cpu.cpu_ticks[CPU_STATE_NICE];
  }
  mach_port_deallocate(mach_task_self(), host);
  out[query_duration_ns] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began;
  return 0;
}
