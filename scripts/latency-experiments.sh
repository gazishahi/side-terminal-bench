#!/bin/zsh
# Phase 0, step 3: setup C's latency with each presentation experiment (TERMBENCH_EXP, see
# GridRenderer), real key events, idle and with five sessions streaming, interleaved, 3 runs.
# A runs alongside as the reference. Results: results/validation/<date>/latency-experiments.jsonl.
set -uo pipefail
here=${HERE:-${0:A:h}/..}; T=$here/TermBench/.build/release; W=$here/workloads
R=$here/results/validation/${VALIDATION_DATE:-$(date +%F)}; mkdir -p $R; out=$R/latency-experiments.jsonl; : > $out
variants=(${=VARIANTS:-base nosync opaque drawables3 nosync,opaque})
for run in 1 2 3; do for l in 0 5; do
  la=$(sysctl -n vm.loadavg | awk '{print $2}')
  TERMBENCH_KEYS=events timeout 120 $T/TermBenchST --setup A --mode latency --load $l --load-workload $W/tui-burst.bin --cols 200 --rows 60 2>/dev/null \
    | grep '^{' | sed "s/}\$/,\"run\":$run,\"loadavg\":$la}/" >> $out
  pkill -f tui-burst.bin; sleep 1
  for v in $variants; do
    la=$(sysctl -n vm.loadavg | awk '{print $2}')
    TERMBENCH_KEYS=events TERMBENCH_EXP=${v:#base} timeout 120 $T/TermBenchGV --setup C --mode latency --load $l --load-workload $W/tui-burst.bin --cols 200 --rows 60 2>/dev/null \
      | grep '^{' | sed "s/}\$/,\"run\":$run,\"loadavg\":$la}/" >> $out
    pkill -f tui-burst.bin; sleep 1
  done
done; done
echo "done: $out"
