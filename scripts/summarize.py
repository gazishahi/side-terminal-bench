"""Prints the tables in docs/BENCHMARKS_*.md from results/*.jsonl.
Usage: python3 -I scripts/summarize.py results"""
import collections
import json
import os
import statistics as st
import sys

R = sys.argv[1]


def load(name):
    path = os.path.join(R, name)
    return [json.loads(l) for l in open(path) if l.strip()] if os.path.exists(path) else []


rows = load('throughput.jsonl')
g = collections.defaultdict(list)
for r in rows:
    if 'seconds' not in r:
        print('FAILED', r)
        continue
    g[(r['grid'], r['workload'], r['setup'])].append(r)
for grid in ['80x24', '200x60']:
    print(f'\n== throughput {grid} (median: MB/s | main-thread CPU s | process CPU s | footprint MB)')
    print(f'{"workload":12}' + ''.join(f'{s:>34}' for s in 'ABCD'))
    for w in ['ascii', 'colors', 'unicode', 'cursor', 'tui', 'scroll']:
        line = f'{w:12}'
        for s in 'ABCD':
            rs = g.get((grid, w + '.bin', s), [])
            if not rs:
                line += f'{"-":>34}'
                continue
            m = lambda k: st.median(r[k] for r in rs)
            line += f'{m("MBps"):>10.1f} {m("mainCPU"):>7.3f} {m("processCPU"):>7.3f} {m("footprintMB"):>6.0f}'
        print(line)

print('\n== frame cost (ms, median/p95; GPU - where there is none)')
for r in load('framecost.jsonl'):
    f = lambda k: '-' if r[k] is None else f'{r[k]["median"]:.2f}/{r[k]["p95"]:.2f}'
    print(f'{r["setup"]} {r["workload"]:9} {r["grid"]:7} fullCPU {f("fullCPU"):>12} fullGPU {f("fullGPU"):>12} rowCPU {f("rowCPU"):>12} rowGPU {f("rowGPU"):>12}')

print('\n== six sessions (median)')
g = collections.defaultdict(list)
for r in load('sessions.jsonl'):
    g[r['setup']].append(r)
for s in sorted(g):
    m = lambda k: st.median(x[k] for x in g[s])
    print(f'{s} mainCPU {m("mainCPU"):.3f}s processCPU {m("processCPU"):.3f}s footprint {m("footprintMB"):.0f}MB runs={len(g[s])}')

print('\n== keypress latency (ms; median across runs of each run\'s median / p95)')
g = collections.defaultdict(list)
for r in load('latency.jsonl'):
    g[(r['load'], r['setup'])].append(r)
for key in sorted(g):
    rs = g[key]
    print(f'load {key[0]} {key[1]} median {st.median(x["medianMs"] for x in rs):.1f} p95 {st.median(x["p95Ms"] for x in rs):.1f} '
          f'min {min(x["minMs"] for x in rs):.1f} timeouts {sum(x["timeouts"] for x in rs)} runs={len(rs)}')
