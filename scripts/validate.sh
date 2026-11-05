#!/bin/zsh
# Phase 0 of Side's terminal engine RFC, step 1: does the harness still reproduce the
# 2026-11-03 numbers, and does latency change when each key is a real key event rather than a
# write straight to the terminal? Runs are interleaved across setups so drift hits all of them
# alike; each line records the load average it ran under. Windows open on screen: leave them
# uncovered. Results go to results/validation/<date>/.
set -uo pipefail
here=${0:A:h}/..; T=$here/TermBench/.build/release; W=$here/workloads
R=$here/results/validation/${VALIDATION_DATE:-$(date +%F)}${TERMBENCH_RELAY:+-keeper}; mkdir -p $R
bin() { case $1 in A|B) echo TermBenchST;; C) echo TermBenchGV;; D) echo TermBenchGK;; esac }
setups=(${=SETUPS:-A C D})
load() { sysctl -n vm.loadavg | awk '{print $2}'; }
# Behind the keeper (TERMBENCH_RELAY set; see Keeper/relay.c), rows are marked "relay":"′".
mark=$([[ -n ${TERMBENCH_RELAY:-} ]] && echo ',"relay":"′"')
# The benchmark's own keepers only, by their run directory: never Side's real ones.
rundir=${${TERMBENCH_RELAY:-}##* }
cleanup() { [[ -n ${TERMBENCH_RELAY:-} ]] && pkill -f -- "--launch $rundir/"; sleep 0.5; }
tag() { sed "s/}\$/,\"run\":$1,\"loadavg\":$2$mark}/"; }

if [[ ${PART:-all} == all || ${PART:-} == latency ]]; then
  : > $R/latency.jsonl
  for run in 1 2 3; do
    for keys in direct events; do for l in 0 5; do for s in $setups; do
      la=$(load)
      TERMBENCH_KEYS=$([[ $keys == events ]] && echo events || echo direct) timeout 120 $T/$(bin $s) --setup $s --mode latency --load $l \
        --load-workload $W/tui-burst.bin --cols 200 --rows 60 2>/dev/null | grep '^{' | tag $run $la >> $R/latency.jsonl
      pkill -f tui-burst.bin; cleanup; sleep 1
    done; done; done
  done
fi

if [[ ${PART:-all} == all || ${PART:-} == throughput ]]; then
  : > $R/throughput.jsonl
  for run in 1 2 3; do
    for w in ascii tui scroll; do for s in $setups; do
      la=$(load)
      line=$(timeout 200 $T/$(bin $s) --setup $s --workload $W/$w.bin --cols 200 --rows 60 2>/dev/null | grep '^{')
      [[ -z $line ]] && line="{\"setup\":\"$s\",\"workload\":\"$w.bin\",\"note\":\"failed\"}"
      echo $line | tag $run $la >> $R/throughput.jsonl
      cleanup
    done; done
  done
fi
echo "done: $R"
