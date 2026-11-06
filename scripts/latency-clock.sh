#!/bin/zsh
# Phase 0, the vsync question: keypress latency of every setup with each clock, the window clock
# (a capture of the window, the clock used so far) and the display clock (the composited display
# frame's own display time, TERMBENCH_CLOCK=display, see DisplayClock.swift). Real keys, idle and
# with five hidden sessions replaying a recording at real pace, interleaved, 3 runs, no keeper.
# The display clock needs Screen Recording permission for the app this runs in (a terminal
# session inside Side doesn't get Side's; Terminal.app works). REC is the recording, PACE pace.c built.
set -uo pipefail
here=${HERE:-${0:A:h}/..}; T=$here/TermBench/.build/release
: ${REC:?the recording} ${PACE:?Capture/pace built}
R=$here/results/validation/${VALIDATION_DATE:-$(date +%F)}-clock; mkdir -p $R; out=$R/latency.jsonl; : > $out
bin() { case $1 in A) echo TermBenchST;; C*) echo TermBenchGV;; D) echo TermBenchGK;; esac }
exp() { case $1 in C-nosync) echo nosync;; *) echo "";; esac }
dump=$R/../clock.bin.tmp; $PACE --dump $REC $dump 2>/dev/null
for run in 1 2 3; do for load in 0 5; do for clock in window display; do for v in A C C-nosync D; do
  la=$(sysctl -n vm.loadavg | awk '{print $2}')
  TERMBENCH_KEYS=events TERMBENCH_CLOCK=$clock TERMBENCH_EXP=$(exp $v) TERMBENCH_LOAD_PACE="$PACE --max-gap 0.5 $REC" \
    timeout 120 $T/$(bin $v) --setup ${v%%-*} --mode latency --load $load --load-workload $dump --cols 200 --rows 60 2>/dev/null \
    | grep '^{' | sed "s/}\$/,\"variant\":\"$v\",\"run\":$run,\"loadavg\":$la}/" >> $out
  pkill -f "$REC"; sleep 0.7
done; done; done; done
rm -f $dump
echo "done: $R"
