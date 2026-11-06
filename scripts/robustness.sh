#!/bin/zsh
# Phase 0, robustness: do C's gains hold where Ghostty's design is built to win? Three runs,
# interleaved, no keeper, real keys, display clock (needs Screen Recording; run from Terminal.app).
#   busy:  keypress latency while the main thread is kept busy (TERMBENCH_MAIN_BUSY ms, 60 times
#          a second), standing in for the app's own UI work
#   stall: how long the main thread waits (TERMBENCH_PROBE) while output streams: bulk workloads
#          and the recording at 10x pace in six sessions
# C draws on the main thread; C-renderthread draws on a thread of its own, as Ghostty does.
# REC is the recording, PACE pace.c built.
set -uo pipefail
here=${HERE:-${0:A:h}/..}; T=$here/TermBench/.build/release; W=$here/workloads
: ${REC:?the recording} ${PACE:?Capture/pace built}
R=$here/results/validation/${VALIDATION_DATE:-$(date +%F)}-robustness; mkdir -p $R
bin() { case $1 in A) echo TermBenchST;; C*) echo TermBenchGV;; D) echo TermBenchGK;; esac }
exp() { case $1 in C-renderthread) echo renderthread;; *) echo "";; esac }
la() { sysctl -n vm.loadavg | awk '{print $2}'; }
tag() { sed "s/}\$/,\"variant\":\"$1\",\"part\":\"$2\",\"run\":$3,\"loadavg\":$4}/"; }
clean() { pkill -f "$REC"; pkill -f tui-burst.bin; sleep 0.7; }
dump=$R/../robustness.bin.tmp; $PACE --dump $REC $dump 2>/dev/null
variants=(A C C-renderthread D)

if [[ ${PART:-all} == all || ${PART:-} == busy ]]; then : > $R/busy.jsonl
for run in 1 2 3; do for busy in 0 5 10; do for v in $variants; do l=$(la)
  TERMBENCH_KEYS=events TERMBENCH_CLOCK=display TERMBENCH_PROBE=1 TERMBENCH_MAIN_BUSY=$busy TERMBENCH_EXP=$(exp $v) \
    timeout 120 $T/$(bin $v) --setup ${v%%-*} --mode latency --load 0 --cols 200 --rows 60 2>/dev/null \
    | grep '^{' | tag $v busy-$busy $run $l >> $R/busy.jsonl; clean
done; done; done; fi

if [[ ${PART:-all} == all || ${PART:-} == stall ]]; then : > $R/stall.jsonl
for run in 1 2 3; do
  for w in tui scroll; do for v in $variants; do l=$(la)
    TERMBENCH_PROBE=1 TERMBENCH_EXP=$(exp $v) timeout 200 $T/$(bin $v) --setup ${v%%-*} --workload $W/$w.bin --cols 200 --rows 60 2>/dev/null \
      | grep '^{' | tag $v stall-$w $run $l >> $R/stall.jsonl; clean
  done; done
  for v in $variants; do l=$(la)
    TERMBENCH_PROBE=1 TERMBENCH_EXP=$(exp $v) TERMBENCH_PACE="$PACE --speed 10 --max-gap 0.5 --limit 20 $REC" timeout 200 $T/$(bin $v) --setup ${v%%-*} \
      --mode sessions --sessions 6 --workload $dump --cols 200 --rows 60 2>/dev/null | grep '^{' | tag $v stall-sessions-x10 $run $l >> $R/stall.jsonl; clean
  done
done; fi
rm -f $dump
echo "done: $R"
