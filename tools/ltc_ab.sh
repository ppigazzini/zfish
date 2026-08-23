#!/usr/bin/env bash
# Paired A/B in the regime a LONG clock reaches: a warm game, at depth.
#
# THE AXIS THE OTHER SIX STRUCTURALLY CANNOT COVER. tools/nps_ab.sh, tools/perf_budget.sh,
# tools/perf_counters and tools/perf_callgrind.sh all measure `bench`, and `bench` is a COLD
# search of a fixed position list at depth 8 or 13. A move at fishtest's 10+0.1 runs at ply 40
# of ONE game, on a transposition table every earlier move has written end to end and on the
# history, pawn and correction banks those moves populated, and it reaches depth 20 to 25.
# A per-node ratio measured in the first regime does not transfer to the second: a change that
# only pays once the table is full reads as nothing on every gate this repo had.
#
# DETERMINISM IS THE FIDELITY CHECK. The move list is fixed input, every search is `go depth D`
# and Threads is 1, so the node count is a function of the position and the table alone. Two
# binaries that search the same tree MUST report the same node total. That is a WIDER net than
# the bench anchor, which visits only its own thirteen positions from a cold table -- the class
# docs/10-tooling-ci.md records the anchor cannot see. A run whose totals differ is VOID, not
# slow, and this script exits 1 rather than printing a ratio.
#
# WHICH COLUMN CARRIES A CLAIM. Retired instructions and retired branches are near-deterministic
# here: two runs of one binary repeat to five decimals. Cache misses and branch misses are
# hardware counters sampling a shared machine, so they are printed WITH the A/A control and
# without it they say nothing. Pass the same binary twice to take that control.
#
# STARTUP IS SUBTRACTED per binary, because two revisions do not pay the same price to map the
# binary and read the .nnue, and a raw total charges that difference to the search.
#
# WHAT THIS DOES NOT DO: build. Compiling before a measurement leaves the machine hot -- the
# rule tools/nps_ab.sh states and the reason it only runs. Build both sides first, let the box
# settle, then measure.
#
# Exit codes:  0 ran (read the verdict)   1 void or failed   2 skipped (no perf_event_open)
#
# Usage: ltc_ab.sh <binA> <binB> [options]      (CWD must be resources/)
#   --depths 13,20     comma-separated fixed depths (default: 13,20)
#   --plies N          plies of the game to replay (default: 60)
#   --hash MB          Hash for the replay (default: 16; fishtest LTC uses 64)
#   --rounds N         paired rounds per depth, order alternating (default: 3)
#   --moves FILE       replay this move list instead of recording one
#   --record-depth D   depth used to RECORD a move list (default: 12)
#   --cold             ucinewgame before every move -- the state-value control
#   --engine-core N    core the engine is pinned to (default: 0)
#   --driver-core N    core the replay driver is pinned to (default: 2)
set -u
set -o pipefail

A="${1:-}"; B="${2:-}"
case "$A" in -*|"") sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;; esac
shift 2 2>/dev/null || { echo "ltc_ab: need two binaries" >&2; exit 1; }

DEPTHS=13,20
PLIES=60
HASH=16
ROUNDS=3
MOVES=
RECORD_DEPTH=12
COLD=
ENGINE_CORE=0
DRIVER_CORE=2

while [ $# -gt 0 ]; do
    case "$1" in
    --depths) DEPTHS=$2; shift 2 ;;
    --plies) PLIES=$2; shift 2 ;;
    --hash) HASH=$2; shift 2 ;;
    --rounds) ROUNDS=$2; shift 2 ;;
    --moves) MOVES=$2; shift 2 ;;
    --record-depth) RECORD_DEPTH=$2; shift 2 ;;
    --cold) COLD=--cold; shift ;;
    --engine-core) ENGINE_CORE=$2; shift 2 ;;
    --driver-core) DRIVER_CORE=$2; shift 2 ;;
    *) echo "ltc_ab: unknown option '$1'" >&2; exit 1 ;;
    esac
done

REPO=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel) || exit 1
REPLAY=$REPO/tools/ltc_replay.py
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

die() { echo "ltc_ab: $*" >&2; exit 1; }
void() { echo "ltc_ab: VOID -- $*" >&2; exit 1; }

for f in "$A" "$B"; do [ -x "$f" ] || die "$f is not executable"; done
[ -f "$REPLAY" ] || die "missing $REPLAY"

# perf_counters is the only part that can be refused by the kernel, and A SKIP IS NOT A PASS:
# exit 2 so a caller testing the exit code cannot read "could not measure" as "did not
# regress" -- the rule tools/perf_budget.sh already states for the same syscall.
COUNTERS=$WORK/perf_counters
zig build-exe "$REPO/tools/perf_counters.zig" -O ReleaseFast -femit-bin="$COUNTERS" \
    >/dev/null 2>&1 || die "cannot build tools/perf_counters.zig"
"$COUNTERS" --wrap -o "$WORK/probe" --core "$ENGINE_CORE" -- /bin/true >/dev/null 2>&1
grep -q 'instructions=[1-9]' "$WORK/probe" 2>/dev/null ||
    { echo "ltc_ab: SKIPPED -- perf_event_open is unavailable here" >&2; exit 2; }

if [ -z "$MOVES" ]; then
    # Record from A. The list is fixed input to BOTH sides from here on, so which binary
    # produced it decides the game and nothing about the comparison.
    MOVES=$WORK/game.moves
    taskset -c "$DRIVER_CORE" python3 "$REPLAY" record --bin "$A" \
        --depth "$RECORD_DEPTH" --plies "$PLIES" --hash "$HASH" >"$MOVES" ||
        die "recording the move list failed"
fi
[ -s "$MOVES" ] || die "the move list is empty"

# One run: echo "nodes instructions cycles cache_misses branch_misses branches".
run() {
    local bin=$1 depth=$2 out=$WORK/out.$$ ctr=$WORK/ctr.$$
    taskset -c "$DRIVER_CORE" python3 "$REPLAY" replay --bin "$bin" --depth "$depth" \
        --moves "$MOVES" --plies "$PLIES" --hash "$HASH" $COLD \
        --counters "$COUNTERS" --counters-out "$ctr" --core "$ENGINE_CORE" >"$out" 2>/dev/null ||
        return 1
    local nodes ins cyc cm bm br
    nodes=$(sed -n 's/^replay:.* nodes=\([0-9]*\) .*/\1/p' "$out")
    read -r ins cyc cm bm br < <(sed -n 's/^counters instructions=\([0-9]*\) cycles=\([0-9]*\) cache_misses=\([0-9]*\) branch_misses=\([0-9]*\) branches=\([0-9]*\)/\1 \2 \3 \4 \5/p' "$out")
    rm -f "$out" "$ctr"
    [ -n "$nodes" ] && [ -n "$ins" ] || return 1
    echo "$nodes $ins $cyc $cm $bm $br"
}

# The startup floor, measured the way the replay opens its own session.
startup() {
    local bin=$1 ctr=$WORK/sctr.$$
    taskset -c "$DRIVER_CORE" python3 "$REPLAY" startup --bin "$bin" --hash "$HASH" \
        --counters "$COUNTERS" --counters-out "$ctr" --core "$ENGINE_CORE" 2>/dev/null |
        sed -n 's/^counters instructions=\([0-9]*\) cycles=\([0-9]*\) cache_misses=\([0-9]*\) branch_misses=\([0-9]*\) branches=\([0-9]*\)/\1 \2 \3 \4 \5/p'
    rm -f "$ctr"
}

SA=$(startup "$A") || die "startup probe failed for $A"
SB=$(startup "$B") || die "startup probe failed for $B"
[ -n "$SA" ] && [ -n "$SB" ] || die "startup probe returned nothing"
echo "ltc_ab: A=$A  B=$B  plies=$PLIES hash=$HASH rounds=$ROUNDS ${COLD:+cold }depths=$DEPTHS"
echo "ltc_ab: startup floor A: $SA"
echo "ltc_ab: startup floor B: $SB"

STATUS=0
for depth in ${DEPTHS//,/ }; do
    ROWS=$WORK/rows.$depth
    : >"$ROWS"
    round=1
    while [ "$round" -le "$ROUNDS" ]; do
        # Alternate which side runs first, so a monotone drift in the box cannot land
        # entirely on one binary.
        if [ $((round % 2)) -eq 1 ]; then
            ra=$(run "$A" "$depth") || die "replay failed (A, depth $depth, round $round)"
            rb=$(run "$B" "$depth") || die "replay failed (B, depth $depth, round $round)"
        else
            rb=$(run "$B" "$depth") || die "replay failed (B, depth $depth, round $round)"
            ra=$(run "$A" "$depth") || die "replay failed (A, depth $depth, round $round)"
        fi
        echo "$ra $rb" >>"$ROWS"
        round=$((round + 1))
    done

    OUT=$(SA="$SA" SB="$SB" DEPTH="$depth" python3 - "$ROWS" <<'PYEOF'
import os, statistics, sys

rows = [list(map(int, line.split())) for line in open(sys.argv[1]) if line.strip()]
sa = list(map(int, os.environ["SA"].split()))
sb = list(map(int, os.environ["SB"].split()))
depth = os.environ["DEPTH"]

# The node total is the fidelity check, not a statistic: every run of both binaries must
# agree, or the two searched different trees and no ratio below means anything.
nodes = {r[0] for r in rows} | {r[6] for r in rows}
if len(nodes) != 1:
    print(f"depth {depth}: node totals differ across runs: {sorted(nodes)}")
    sys.exit(3)
n = nodes.pop()

# instructions, cycles, cache misses, branch misses, branches -- in the order run() emits.
COLS = [("Ir", 1), ("cycles", 2), ("miss", 3), ("brmiss", 4), ("branches", 5)]
print(f"depth {depth}   nodes {n}   rounds {len(rows)}")
print(f"  {'column':10} {'A/node':>14} {'B/node':>14} {'B/A':>10}")
for name, i in COLS:
    # Subtract each binary's OWN startup: the two do not pay the same price to map the
    # binary and read the net, and charging that difference to the search is the error
    # this column exists to avoid.
    a = [(r[i] - sa[i - 1]) / n for r in rows]
    b = [(r[6 + i] - sb[i - 1]) / n for r in rows]
    ratios = [y / x for x, y in zip(a, b) if x]
    # Median of PER-ROUND PAIRED ratios, never the ratio of medians: under drift the two
    # disagreed by 2x on a real change here (tools/nps_ab.sh records the case).
    print(f"  {name:10} {statistics.median(a):14.3f} {statistics.median(b):14.3f} "
          f"{statistics.median(ratios):10.5f}")
PYEOF
    )
    rc=$?
    echo "$OUT"
    # 3 is the reducer's own "the trees differ" exit. Capture it BEFORE the echo: `$?` after
    # a print refers to the print, which is how a void run would have reported a ratio.
    [ "$rc" -eq 3 ] && void "node totals moved -- the two searched different trees"
    [ "$rc" -eq 0 ] || STATUS=1
done

exit $STATUS
