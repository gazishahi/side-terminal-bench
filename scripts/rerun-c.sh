#!/bin/zsh
# Re-runs everything involving libghostty-vt after the scrollback byte-limit fix (2026-11-03),
# into results/rerun-c/, leaving the other setups' results as they were.
here=${0:A:h}/..; T=$here/TermBench/.build/release; W=${WORKLOADS:-$here/workloads}; R=$here/results/rerun-c; mkdir -p $R
# The ascii workload is a directory of Swift sources: Side's own for the committed results.
src=${SOURCE:-$here/../../SIDE}; [[ -d $src ]] || { echo "set SOURCE to a directory of Swift sources (the ascii workload)" >&2; exit 2; }
(cd $here/VTBench && swift build -c release >/dev/null) && (cd $here/TermBench && swift build -c release --product TermBenchGV >/dev/null) || exit 1
$here/VTBench/.build/release/VTBench $src > $R/emulator-only.txt
: > $R/throughput.jsonl; : > $R/framecost.jsonl; : > $R/sessions.jsonl; : > $R/latency.jsonl; : > $R/scaling.jsonl
for run in 1 2 3; do for grid in "80 24" "200 60"; do set -- ${=grid}; for w in ascii colors unicode cursor tui scroll; do
  line=$(timeout 200 $T/TermBenchGV --setup C --workload $W/$w.bin --cols $1 --rows $2 2>/dev/null | grep '^{'); echo "${line%\}},\"run\":$run}" >> $R/throughput.jsonl
done; done; done
for grid in "80 24" "200 60" "440 96"; do set -- ${=grid}; for w in tui ascii; do
  timeout 200 $T/TermBenchGV --setup C --mode framecost --workload $W/$w.bin --cols $1 --rows $2 2>/dev/null | grep '^{' >> $R/framecost.jsonl
done; done
for run in 1 2 3; do
  timeout 200 $T/TermBenchGV --setup C --mode sessions --sessions 6 --workload $W/tui-burst.bin --cols 200 --rows 60 2>/dev/null | grep '^{' | sed "s/}\$/,\"run\":$run}/" >> $R/sessions.jsonl
  for load in 0 5; do timeout 120 $T/TermBenchGV --setup C --mode latency --load $load --load-workload $W/tui-burst.bin --cols 200 --rows 60 2>/dev/null | grep '^{' | sed "s/}\$/,\"run\":$run}/" >> $R/latency.jsonl; pkill -f tui-burst.bin; sleep 1; done
done
for run in 1 2; do for n in 1 6 12 24; do
  timeout 240 $T/TermBenchGV --setup C --mode sessions --sessions $n --workload $W/tui-burst.bin --cols 200 --rows 60 2>/dev/null | grep '^{' | sed "s/}\$/,\"run\":$run}/" >> $R/scaling.jsonl; pkill -f tui-burst.bin; sleep 1
done; done
echo done
