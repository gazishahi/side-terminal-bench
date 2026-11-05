// Replays the output of a real terminal session recorded with macOS script(1):
//
//   script -r session.rec claude        record (input and output, with timing)
//   pace session.rec                    write its output at the pace it was recorded
//   pace --fast session.rec             write its output as fast as the terminal takes it
//   pace --dump session.rec out.bin     its output alone, as a workload file
//   pace --speed 10 --limit 60 s.rec    ten times the recorded pace, the first 60 s of the result
//
// The recording is script's own format (script.c, struct stamp): for each record a 24-byte
// header (length, seconds, microseconds, direction), then the bytes. Only output ('o') is
// replayed; what was typed ('i') isn't, since the terminal under test didn't produce it.
// A paced replay sleeps for the gaps, capped at --max-gap seconds (default 2), so a session
// that sat waiting for a person doesn't stretch the benchmark.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct stamp { uint64_t len; uint64_t sec; uint32_t usec; uint32_t direction; };

static void write_all(int fd, const char *p, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w <= 0) exit(1);
        p += w; n -= (size_t)w;
    }
}

static double now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    int fast = 0, dump = 0; double max_gap = 2.0, speed = 1.0, limit = 0;
    int i = 1;
    for (; i < argc && argv[i][0] == '-'; i++) {
        if (!strcmp(argv[i], "--fast")) fast = 1;
        else if (!strcmp(argv[i], "--dump")) dump = 1;
        else if (!strcmp(argv[i], "--max-gap") && i + 1 < argc) max_gap = atof(argv[++i]);
        else if (!strcmp(argv[i], "--speed") && i + 1 < argc) speed = atof(argv[++i]);
        else if (!strcmp(argv[i], "--limit") && i + 1 < argc) limit = atof(argv[++i]);
    }
    if (i >= argc) { fprintf(stderr, "usage: pace [--fast|--dump] [--max-gap s] [--speed x] [--limit s] session.rec [out.bin]\n"); return 2; }
    FILE *in = fopen(argv[i], "rb");
    if (!in) { perror(argv[i]); return 1; }
    int out = STDOUT_FILENO;
    FILE *dumpf = NULL;
    if (dump) {
        if (i + 1 >= argc) { fprintf(stderr, "--dump needs an output file\n"); return 2; }
        dumpf = fopen(argv[i + 1], "wb");
        if (!dumpf) { perror(argv[i + 1]); return 1; }
    }
    struct stamp s;
    double last = -1, clock = now(), behind = 0;
    size_t cap = 1 << 16; char *buf = malloc(cap);
    uint64_t records = 0, bytes = 0;
    while (fread(&s, sizeof s, 1, in) == 1) {
        if (s.len > cap) { cap = s.len; buf = realloc(buf, cap); }
        if (s.len && fread(buf, 1, s.len, in) != s.len) break;
        if (s.direction != 'o' || s.len == 0) continue;
        double t = (double)s.sec + (double)s.usec / 1e6;
        if (dump) { fwrite(buf, 1, s.len, dumpf); records++; bytes += s.len; continue; }
        if (!fast && last >= 0) {
            double gap = t - last;
            if (gap > max_gap) gap = max_gap;
            gap /= speed;
            if (limit > 0 && behind + gap > limit) break;
            if (gap > 0) {
                // Sleep to the record's time on our own clock, so small gaps don't drift.
                behind += gap;
                double wait = clock + behind - now();
                if (wait > 0) usleep((useconds_t)(wait * 1e6));
            }
        }
        last = t;
        write_all(out, buf, s.len);
        records++; bytes += s.len;
    }
    if (dumpf) fclose(dumpf);
    fprintf(stderr, "pace: %llu output records, %llu bytes\n", (unsigned long long)records, (unsigned long long)bytes);
    return 0;
}
