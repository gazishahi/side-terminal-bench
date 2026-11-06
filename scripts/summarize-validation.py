#!/usr/bin/env python3
"""Tables from a validation run (scripts/validate.sh) or a replay (scripts/replay.sh): the median
across runs of each setup's median, with every run's value beside it so the spread is visible,
and the load average the runs saw.

    python3 -I scripts/summarize-validation.py results/validation/2026-11-05
    python3 -I scripts/summarize-validation.py results/validation/2026-11-05-capture
"""
import json
import os
import statistics
import sys
from collections import defaultdict


def rows(path):
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path):
        line = line.strip()
        if line.startswith("{"):
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


def main(folder):
    for name in ("latency.jsonl", "latency-experiments.jsonl"):
        latency_table(rows(os.path.join(folder, name)), name)
    throughput_table(rows(os.path.join(folder, "throughput.jsonl")))
    throughput_table(rows(os.path.join(folder, "full.jsonl")))
    sessions_table(rows(os.path.join(folder, "sessions.jsonl")))


def latency_table(latency, name):
    if latency:
        print(name)
        print("Keypress latency, ms (median of runs; each run's median in brackets)")
        print("| Setup | Keys | Clock | Experiment | Load | Median | p95 | Runs | Load avg |")
        print("|---|---|---|---|---|---|---|---|---|")
        groups = defaultdict(list)
        for r in latency:
            groups[(r.get("relay", ""), r["setup"], r.get("input", "direct"), r.get("clock", "window"), r.get("exp", ""), r["load"])].append(r)
        for (relay, setup, keys, clock, exp, load), rs in sorted(groups.items()):
            meds = [r["medianMs"] for r in rs]
            p95s = [r["p95Ms"] for r in rs]
            loads = [r.get("loadavg", 0) for r in rs]
            print(f"| {setup}{relay} | {keys} | {clock} | {exp or '-'} | {load} | {statistics.median(meds):.1f} | {statistics.median(p95s):.1f} | "
                  f"{', '.join(f'{m:.1f}' for m in meds)} | {max(loads):.1f} |")
        print()


def throughput_table(throughput):
    if throughput:
        print("Throughput, MB/s, and CPU s main / process (median of runs)")
        print("| Workload | Setup | MB/s | Runs | Main CPU | Process CPU | Load avg |")
        print("|---|---|---|---|---|---|---|")
        groups = defaultdict(list)
        for r in throughput:
            if "MBps" in r:
                groups[(r["workload"], r.get("relay", ""), r.get("variant", r["setup"]))].append(r)
        for (w, relay, setup), rs in sorted(groups.items()):
            mb = [r["MBps"] for r in rs]
            print(f"| {w} | {setup}{relay} | {statistics.median(mb):.1f} | {', '.join(f'{m:.0f}' for m in mb)} | "
                  f"{statistics.median([r['mainCPU'] for r in rs]):.2f} | {statistics.median([r['processCPU'] for r in rs]):.2f} | "
                  f"{max(r.get('loadavg', 0) for r in rs):.1f} |")
        print()


def sessions_table(sessions):
    if sessions:
        print("Sessions, one shown: CPU s main / process, footprint MB, frames (median of runs)")
        print("| Part | Setup | Process CPU | Runs | Main CPU | MB | Frames | Load avg |")
        print("|---|---|---|---|---|---|---|---|")
        groups = defaultdict(list)
        for r in sessions:
            if "processCPU" in r:
                groups[(r.get("part", r["mode"]), r.get("relay", ""), r.get("variant", r["setup"]))].append(r)
        for (part, relay, setup), rs in sorted(groups.items()):
            cpu = [r["processCPU"] for r in rs]
            print(f"| {part} | {setup}{relay} | {statistics.median(cpu):.2f} | {', '.join(f'{c:.2f}' for c in cpu)} | "
                  f"{statistics.median([r['mainCPU'] for r in rs]):.2f} | {statistics.median([r['footprintMB'] for r in rs]):.0f} | "
                  f"{statistics.median([r['frames'] for r in rs]):.0f} | {max(r.get('loadavg', 0) for r in rs):.1f} |")
        print()


if __name__ == "__main__":
    main(sys.argv[1])
