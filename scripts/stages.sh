#!/bin/zsh
# Phase 0: where each setup's keypress latency goes (TERMBENCH_STAGES, see Stages.swift). Real
# keys, idle, display clock, 3 runs interleaved, no keeper:
#   C               draws on the main thread
#   C-renderthread  draws on a thread of its own
#   D               full libghostty with vsync (its default)
#   D-novsync       full libghostty with window-vsync = false
# The display clock needs Screen Recording permission for the app this runs in (a terminal
# session inside Side doesn't get Side's; Terminal.app works).
set -uo pipefail
here=${HERE:-${0:A:h}/..}; T=$here/TermBench/.build/release
R=$here/results/validation/${VALIDATION_DATE:-$(date +%F)}-stages; mkdir -p $R; out=$R/latency.jsonl; : > $out
for run in 1 2 3; do for v in C C-renderthread D D-novsync; do
  e=""; g=""; b=TermBenchGV; s=C
  [[ $v == C-renderthread ]] && e=renderthread
  [[ $v == D* ]] && { b=TermBenchGK; s=D; }
  [[ $v == D-novsync ]] && g="window-vsync = false"
  la=$(sysctl -n vm.loadavg | awk '{print $2}')
  TERMBENCH_STAGES=1 TERMBENCH_KEYS=events TERMBENCH_CLOCK=display TERMBENCH_EXP=$e TERMBENCH_GHOSTTY_CONFIG="$g" \
    timeout 120 $T/$b --setup $s --mode latency --load 0 --cols 200 --rows 60 2>/dev/null | grep '^{' \
    | sed "s/}\$/,\"variant\":\"$v\",\"run\":$run,\"loadavg\":$la}/" >> $out
  sleep 0.7
done; done
echo "done: $R"
