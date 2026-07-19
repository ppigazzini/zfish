#!/usr/bin/env sh
# ThreadSanitizer race gate.
#
# The engine's cross-thread state -- the TT, the shared history tables, the per-Worker counters,
# the Syzygy registry -- is raced BY DESIGN, and upstream makes that race defined by typing every
# such field RelaxedAtomic. A missed atomic is not a crash: it is undefined behaviour the compiler
# may exploit, and no node-count gate can see it. TSan is the instrument that can.
#
# Drive four workloads that each reach different shared state, and require ZERO reports:
#   1. deep search, tiny hash, many threads   -- TT and history collisions
#   2. tablebases + MultiPV                   -- Syzygy registry and the PV emitter
#   3. go/stop churn across thread counts     -- pool lifecycle, TT clear vs a live search
#   4. ucinewgame between searches            -- clear/reset paths
#
# Usage: tsan_race.sh [<stockfish-bin>]   (built with -Dtsan; run from the repo root)
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$REPO/zig-out/bin/stockfish}"
RES="$REPO/resources"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

[ -x "$BIN" ] || { echo "tsan-race: no binary at $BIN (build with -Dtsan)" >&2; exit 2; }

total=0
run_case() {
    name="$1"; secs="$2"; script="$3"
    printf 'tsan-race: %s ...\n' "$name"
    # shellcheck disable=SC2059
    { printf "$script"; sleep "$secs"; printf 'quit\n'; } | ( cd "$RES" && "$BIN" ) 2>"$LOG" >/dev/null || true
    n="$(grep -c 'WARNING: ThreadSanitizer' "$LOG" 2>/dev/null || true)"
    n="${n:-0}"
    total=$((total + n))
    if [ "$n" -ne 0 ]; then
        echo "tsan-race: $name -- $n report(s):" >&2
        grep -E 'WARNING: ThreadSanitizer|^    #0 ' "$LOG" | sed -E 's/ \(stockfish.*//' | head -20 >&2
    fi
}

run_case "deep search, 8 threads, 1MB hash" 20 \
    'setoption name Threads value 8\nsetoption name Hash value 1\nposition startpos\ngo depth 12\n'
run_case "tablebases + MultiPV" 20 \
    'setoption name Threads value 8\nsetoption name SyzygyPath value syzygy\nsetoption name MultiPV value 3\nsetoption name Hash value 1\nposition fen 8/8/8/3k4/8/8/3K1R2/8 w - - 0 1\ngo depth 18\n'
run_case "go/stop churn across thread counts" 14 \
    'setoption name Threads value 8\nposition startpos\ngo infinite\n'
run_case "ucinewgame + thread-count change between searches" 20 \
    'setoption name Threads value 4\nposition startpos\ngo depth 10\nucinewgame\nsetoption name Threads value 16\nposition startpos\ngo depth 10\n'

if [ "$total" -ne 0 ]; then
    echo "tsan-race: FAILED -- $total data race report(s)" >&2
    exit 1
fi
echo "tsan-race: OK (4 workloads, 0 data races)"
