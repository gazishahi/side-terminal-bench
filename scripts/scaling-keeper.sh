#!/bin/zsh
# Phase 0: many sessions behind Side's session keeper. 1, 6 and 24 sessions (one shown), each
# behind its own keeper (Keeper/relay.c), interleaved, 3 runs:
#   burst: the 11-03 scaling load (tui-burst.bin looped, about 260 KB/s per session, ~10 s)
#   real:  the recording at real pace for 60 s (24 sessions only)
# The harness reports its own CPU and footprint. The keepers are separate processes, the same for
# every setup; their summed RSS, sampled near the end of each run, is added as "keepersMB".
# REC is the recording, PACE pace.c built, RELAY keeper-relay built, KEEPER SideSessionKeeper.
set -uo pipefail
here=${HERE:-${0:A:h}/..}; T=$here/TermBench/.build/release; W=$here/workloads
: ${REC:?the recording} ${PACE:?Capture/pace built} ${RELAY:?keeper-relay built} ${KEEPER:?SideSessionKeeper}
R=$here/results/validation/${VALIDATION_DATE:-$(date +%F)}-scaling; mkdir -p $R; out=$R/sessions.jsonl; : > $out
bin() { case $1 in A) echo TermBenchST;; C) echo TermBenchGV;; D) echo TermBenchGK;; esac }
export TERMBENCH_RELAY="$RELAY $KEEPER /tmp/tbk"; mkdir -p /tmp/tbk; chmod 700 /tmp/tbk
# The benchmark's own keepers only, by their run directory: never Side's real ones.
keepers() { pgrep -f -- "--launch /tmp/tbk/" | tr '\n' ',' | sed 's/,$//'; }
rss() { local p=$(keepers); [[ -z $p ]] && echo 0 || ps -o rss= -p $p | awk '{s+=$1} END {printf "%.0f", s/1024}'; }
clean() { pkill -f -- "--launch /tmp/tbk/"; pkill -f tui-burst.bin; pkill -f "$REC"; sleep 1; }
dump=$R/../scaling.bin.tmp; $PACE --dump $REC $dump 2>/dev/null

one() { # setup sessions part sample-after workload [pace command]
  local s=$1 n=$2 part=$3 at=$4 w=$5 pace=${6:-}
  local la=$(sysctl -n vm.loadavg | awk '{print $2}') f=$R/.k
  rm -f $f; (sleep $at; rss > $f) &
  local line=$(env ${pace:+TERMBENCH_PACE=$pace} timeout 240 $T/$(bin $s) --setup $s --mode sessions --sessions $n \
    --workload $w --cols 200 --rows 60 2>/dev/null | grep '^{')
  wait
  [[ -n $line ]] || line="{\"setup\":\"$s\",\"sessions\":$n,\"note\":\"failed\"}"
  echo $line | sed "s/}\$/,\"part\":\"$part\",\"run\":$run,\"loadavg\":$la,\"keepersMB\":$(cat $f 2>/dev/null || echo -1),\"relay\":\"′\"}/" >> $out
  clean
}

for run in 1 2 3; do
  for n in 1 6 24; do for s in A C D; do
    one $s $n burst 8 $W/tui-burst.bin
  done; done
  for s in A C D; do
    one $s 24 real-60s 50 $dump "$PACE --max-gap 0.5 --limit 60 $REC"
  done
done
rm -f $dump $R/.k
echo "done: $R"
