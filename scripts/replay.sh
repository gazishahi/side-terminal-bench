#!/bin/zsh
# Phase 0, step 1 of Side's terminal engine RFC: a real Claude Code session, recorded with
# script(1), replayed through every setup, 3 runs interleaved. REC is the recording (kept out of
# git: it holds a real conversation; record your own, see README). With KEEPER and RELAY set, every
# setup runs behind Side's session keeper (Keeper/relay.c) and rows are marked "relay":"′";
# without them, the setups read their PTYs directly and results go to <date>-capture-direct/.
#   full:      the recording's output as fast as each terminal takes it
#   sessions:  six sessions (one shown) each replaying it at 10x pace for 20 s, and at real pace
#              for 60 s: CPU, main-thread CPU, frames and memory
#   latency:   real key events, idle and with five hidden sessions replaying it at real pace
set -uo pipefail
here=${HERE:-${0:A:h}/..}; T=$here/TermBench/.build/release
: ${REC:?the recording} ${PACE:?Capture/pace built}
keeper=$([[ -n ${KEEPER:-} && -n ${RELAY:-} ]] && echo 1)
R=$here/results/validation/${VALIDATION_DATE:-$(date +%F)}-capture${keeper:--direct}; mkdir -p $R
bin() { case $1 in A) echo TermBenchST;; C*) echo TermBenchGV;; D) echo TermBenchGK;; esac }
exp() { case $1 in C-nosync) echo nosync;; *) echo "";; esac }
hold() { case $1 in C-nohold) echo 1;; *) echo "";; esac }
la() { sysctl -n vm.loadavg | awk '{print $2}'; }
mark=${keeper:+,\"relay\":\"′\"}
tag() { sed "s/}\$/,\"variant\":\"$1\",\"part\":\"$2\",\"run\":$3,\"loadavg\":$4$mark}/"; }
clean() { pkill -f -- "--launch /tmp/tbk/"; pkill -f "$REC"; sleep 0.7; }
if [[ -n $keeper ]]; then export TERMBENCH_RELAY="$RELAY $KEEPER /tmp/tbk"; mkdir -p /tmp/tbk; chmod 700 /tmp/tbk; fi
dump=$R/../claude.bin.tmp; $PACE --dump $REC $dump 2>/dev/null

if [[ ${PART:-all} == all || ${PART:-} == full ]]; then : > $R/full.jsonl
for run in 1 2 3; do for v in A C C-nohold D; do l=$(la)
  TERMBENCH_NOHOLD=$(hold $v) TERMBENCH_PACE="$PACE --fast $REC" timeout 200 $T/$(bin $v) --setup ${v%%-*} --workload $dump --cols 200 --rows 60 2>/dev/null \
    | grep '^{' | tag $v full $run $l >> $R/full.jsonl; clean
done; done; fi

if [[ ${PART:-all} == all || ${PART:-} == sessions ]]; then : > $R/sessions.jsonl
for run in 1 2 3; do for pace in "10 20" "1 60"; do set -- ${=pace}; for v in A C D; do l=$(la)
  TERMBENCH_PACE="$PACE --speed $1 --max-gap 0.5 --limit $2 $REC" timeout 200 $T/$(bin $v) --setup $v --mode sessions --sessions 6 --workload $dump --cols 200 --rows 60 2>/dev/null \
    | grep '^{' | tag "$v" "sessions-x$1-${2}s" $run $l >> $R/sessions.jsonl; clean
done; done; done; fi

if [[ ${PART:-all} == all || ${PART:-} == latency ]]; then : > $R/latency.jsonl
for run in 1 2 3; do for load in 0 5; do for v in A C C-nosync D; do l=$(la)
  TERMBENCH_KEYS=events TERMBENCH_EXP=$(exp $v) TERMBENCH_LOAD_PACE="$PACE --max-gap 0.5 $REC" timeout 120 $T/$(bin $v) --setup ${v%%-*} --mode latency --load $load \
    --load-workload $dump --cols 200 --rows 60 2>/dev/null | grep '^{' | tag $v latency $run $l >> $R/latency.jsonl; clean
done; done; done; fi
rm -f $dump
echo "done: $R"
