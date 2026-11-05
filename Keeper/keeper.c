// Measures the session keeper design in Side's session restore RFC (Memory). Build:
//   clang -O2 -o keeper keeper.c -I../.ghostty/zig-out/include ../.ghostty/zig-out/lib/libghostty-vt.a
// Run: NOBYTELIMIT=1 ./keeper ../workloads/ascii.bin
// Minimal session keeper prototype: a PTY, its child, and a headless libghostty-vt terminal fed
// every byte. Prints its own memory at three points: idle at a prompt, after the workload has
// filled scrollback, and after compressing that scrollback.
#include <ghostty/vt.h>
#include <libproc.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <util.h>
#include <sys/resource.h>
#include <signal.h>
#include <mach/mach_time.h>
static double now_ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * tb.numer / tb.denom / 1e6; }

static double footprint_mb(void) {
  struct rusage_info_v4 ri;
  proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri);
  return ri.ri_phys_footprint / 1048576.0;
}

static void report(const char *when, GhosttyTerminal t) {
  GhosttyTerminalMemoryUsage m = GHOSTTY_INIT_SIZED(GhosttyTerminalMemoryUsage);
  ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MEMORY_USAGE, &m);
  size_t rows = 0; ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &rows);
  printf("%-22s scrollback %6zu rows | footprint %6.2f MB | terminal pages resident %6.2f MB (%llu pages, %llu compressed)\n", when, rows, footprint_mb(),
         (m.primary_resident_bytes + m.alternate_resident_bytes) / 1048576.0, m.primary_pages + m.alternate_pages, m.primary_compressed_pages);
  fflush(stdout);
}

// Reads until the PTY has been quiet for `quiet_ms`.
static size_t total = 0;
static void pump(int fd, GhosttyTerminal t, int quiet_ms) {
  static uint8_t buf[65536];
  struct pollfd p = {fd, POLLIN, 0};
  while (poll(&p, 1, quiet_ms) > 0) {
    ssize_t n = read(fd, buf, sizeof buf);
    if (n <= 0) break;
    ghostty_terminal_vt_write(t, buf, (size_t)n);
    total += (size_t)n;
  }
}

int main(int argc, char **argv) {
  const char *workload = argc > 1 ? argv[1] : "/dev/null";
  struct winsize ws = {60, 200, 0, 0};
  int fd;
  pid_t pid = forkpty(&fd, NULL, NULL, &ws);
  if (pid == 0) {
    // A shell at a prompt, then (on a line from the keeper) the workload, then idle.
    execl("/bin/sh", "sh", "-c", "read _; cat \"$0\"; exec sleep 600", workload, (char *)NULL);
    _exit(127);
  }
  GhosttyTerminal t = NULL;
  ghostty_terminal_new(NULL, &t, 200, 60);
  size_t lines = 10000;
  ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines);
  size_t maxBytes = 0; ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES, &maxBytes);
  printf("default scrollback byte limit: %zu\n", maxBytes);
  if (getenv("NOBYTELIMIT")) ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, NULL);
  pump(fd, t, 300);
  report("idle", t);
  write(fd, "\n", 1);
  pump(fd, t, 1000);
  printf("bytes read: %zu\n", total);
  report("scrollback full", t);
  // Snapshot of uncompressed scrollback, for comparison.
  uint8_t *snap = NULL; size_t snapLen = 0;
  double s0 = now_ms(); ghostty_snapshot_encode_alloc(t, NULL, &snap, &snapLen); double s1 = now_ms();
  printf("snapshot, uncompressed: %.2f ms, %.2f MB\n", s1 - s0, snapLen / 1048576.0); ghostty_free(NULL, snap, snapLen);
  // Incremental steps, as an idle callback would run them; each step's longest pause matters.
  GhosttyTerminalCompressionResult r; int steps = 0; double worst = 0, c0 = now_ms();
  do { double a = now_ms(); ghostty_terminal_compress(t, GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL, &r); double b = now_ms(); if (b - a > worst) worst = b - a; steps++; } while (r == GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING);
  printf("incremental compression: %d steps, %.2f ms total, longest step %.3f ms\n", steps, now_ms() - c0, worst);
  report(r == GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED ? "compressed (unsupported)" : "compressed", t);
  // A snapshot of compressed scrollback (what a reattach or a disk write does): decompresses as it reads.
  s0 = now_ms(); ghostty_snapshot_encode_alloc(t, NULL, &snap, &snapLen); s1 = now_ms();
  printf("snapshot, compressed:   %.2f ms, %.2f MB\n", s1 - s0, snapLen / 1048576.0); ghostty_free(NULL, snap, snapLen);
  report("after snapshot", t);
  // New output after compression: does writing slow down?
  write(fd, "", 0);
  kill(pid, 9);
  return 0;
}
