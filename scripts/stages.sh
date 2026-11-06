#!/bin/zsh
# Phase 0: where each setup's keypress latency goes (TERMBENCH_STAGES, see Stages.swift). Real
# keys, idle, display clock, 3 runs interleaved, no keeper:
#   C               draws on the main thread
#   C-renderthread  draws on a thread of its own
#   D               full libghostty with vsync (its default)
#   D-novsync       full libghostty with window-vsync = false
#   C-iosurface, C-iosurface-renderthread
#                   frames handed to a plain layer as IOSurface contents, as Ghostty does
# VARIANTS picks a subset (default: all six).
# The display clock needs Screen Recording permission for the app this runs in (a terminal
# session inside Side doesn't get Side's; Terminal.app works).
set -uo pipefail
here=${HERE:-${0:A:h}/..}; T=$here/TermBench/.build/release
R=$here/results/validation/${VALIDATION_DATE:-$(date +%F)}-stages; mkdir -p $R; out=$R/latency.jsonl; : > $out
variants=(${=VARIANTS:-C C-renderthread C-iosurface C-iosurface-renderthread D D-novsync})
for run in 1 2 3; do for v in $variants; do
  e=""; g=""; b=TermBenchGV; s=C
  case $v in C-renderthread) e=renderthread;; C-iosurface) e=iosurface;; C-iosurface-renderthread) e=iosurface,renderthread;; esac
  [[ $v == D* ]] && { b=TermBenchGK; s=D; }
  [[ $v == D-novsync ]] && g="window-vsync = false"
  la=$(sysctl -n vm.loadavg | awk '{print $2}')
  TERMBENCH_STAGES=1 TERMBENCH_KEYS=events TERMBENCH_CLOCK=display TERMBENCH_EXP=$e TERMBENCH_GHOSTTY_CONFIG="$g" \
    timeout 120 $T/$b --setup $s --mode latency --load 0 --cols 200 --rows 60 2>/dev/null | grep '^{' \
    | sed "s/}\$/,\"variant\":\"$v\",\"run\":$run,\"loadavg\":$la}/" >> $out
  sleep 0.7
done; done
echo "done: $R"
