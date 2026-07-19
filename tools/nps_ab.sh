#!/usr/bin/env bash
# Interleaved paired nps A/B between two engine binaries.
#
# The headline speed ratio, and the ONLY sound way to take it on this hardware. Needs no
# instrumentation: both binaries are run as shipped.
#
# THE PROTOCOL, AND WHY EACH PART EXISTS (every rule below was paid for by a wrong result):
#
#  * INTERLEAVED, NOT BATCHED. Absolute nps is thermally void: the SAME binary has read
#    511,286 in one batch and 581,024 in another -- a 13.6% swing that dwarfs most changes.
#    A number from a previous session is NEVER comparable. Only same-run pairs count.
#  * MEDIAN OF PER-ROUND PAIRED RATIOS, not the ratio of medians. Under drift the paired
#    estimator is far more robust: the two disagreed by 2x on a real change here (+6.6% vs
#    the correct +3.2%). When they disagree, report the paired one.
#  * taskset -c 0. Pins both to one core so they see the same thermal/frequency state.
#  * NEVER BUILD IN THE SAME COMMAND. Compiling before a measurement leaves the machine hot;
#    doing so once produced a round reading 934k next to a 2.5M neighbour. Build first, let
#    it idle, then measure. This script refuses to help you break that -- it only runs.
#  * SUB-5% CHANGES DO NOT BELONG HERE AT ALL. Use tools/perf_callgrind.sh; it is
#    deterministic. nps has both falsely confirmed and falsely refuted changes in this repo.
#
# Node counts are asserted equal up front: different trees mean different workloads and the
# ratio would be meaningless.
#
# Usage: nps_ab.sh <binA> <binB> [rounds] [bench-args...]   (CWD must be resources/)
#        nps_ab.sh ./zf ./sf 10 16 1 13
set -u

A="${1:?usage: nps_ab.sh <binA> <binB> [rounds] [bench-args...]  (run with CWD=resources/)}"
B="${2:?usage: nps_ab.sh <binA> <binB> [rounds] [bench-args...]}"
ROUNDS="${3:-8}"
shift 3 2>/dev/null || shift $#
BENCH="${*:-16 1 13}"

for f in "$A" "$B"; do [ -x "$f" ] || { echo "error: $f not executable" >&2; exit 1; }; done

nodes() { taskset -c 0 "$1" bench $BENCH 2>&1 | sed -n 's/^Nodes searched  *: *\([0-9]*\)/\1/p'; }
nps()   { taskset -c 0 "$1" bench $BENCH 2>&1 | sed -n 's/^Nodes\/second  *: *\([0-9]*\).*/\1/p'; }

NA=$(nodes "$A"); NB=$(nodes "$B")
if [ "$NA" != "$NB" ]; then
  echo "error: node counts differ ($A=$NA, $B=$NB)." >&2
  echo "       Different trees = different workloads; the ratio would be meaningless." >&2
  exit 1
fi
echo "# tree: $NA nodes (identical on both) | bench $BENCH | $ROUNDS rounds | core 0"

RATIOS=()
for i in $(seq "$ROUNDS"); do
  a=$(nps "$A"); b=$(nps "$B")
  r=$(awk -v x="$a" -v y="$b" 'BEGIN{printf "%.4f", (y>0)? x/y : 0}')
  RATIOS+=("$r")
  printf "round %-3s A=%-10s B=%-10s A/B=%s\n" "$i" "$a" "$b" "$r"
done

printf '%s\n' "${RATIOS[@]}" | sort -n | awk '
  {v[NR]=$1}
  END{
    m = (NR%2) ? v[(NR+1)/2] : (v[NR/2]+v[NR/2+1])/2
    printf "\n# MEDIAN PAIRED A/B ratio = %.4f  (A is %+.1f%% vs B)\n", m, (m-1)*100
    printf "# spread %.4f..%.4f over %d rounds", v[1], v[NR], NR
    if (v[NR]/v[1] > 1.25) printf "  <-- WIDE: machine is drifting, treat as indicative only"
    printf "\n# Median of PER-ROUND ratios (not ratio of medians). Under 5%%? Use perf_callgrind.sh.\n"
  }'
