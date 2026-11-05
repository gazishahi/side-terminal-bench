#!/bin/zsh
# Writes the six workloads (deterministic; ascii is the Swift sources in $SOURCE) and the 13 KB
# Claude-shaped burst the sessions and latency runs stream.
set -euo pipefail
here=${0:A:h}/..
# The ascii workload is a directory of Swift sources: Side's own for the committed results.
src=${SOURCE:-$here/../../SIDE}; [[ -d $src ]] || { echo "set SOURCE to a directory of Swift sources (the ascii workload)" >&2; exit 2; }
out=$here/workloads; mkdir -p $out
(cd $here/VTBench && swift build -c release)
$here/VTBench/.build/release/VTBench $src dump $out
python3 -I - $out <<'PY'
import sys
out = sys.argv[1]
d = open(f'{out}/tui.bin', 'rb').read()
mark = b'\x1b[?25l'
starts = [i for i in range(len(d)) if d.startswith(mark, i)][:40]
end = next(s for s in starts if s >= 10_000)
open(f'{out}/tui-burst.bin', 'wb').write(d[:end])
PY
ls -la $out
