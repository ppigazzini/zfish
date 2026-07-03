#!/usr/bin/env bash
# Deterministic non-bench search-mode differential harness (M2 Worker-runtime port).
#
# Plain `bench` only exercises a fixed-depth search. iterative_deepening has more
# deterministic control flow that bench never reaches: the node-limited stop, the
# MultiPV root loop (pvIdx/pvLast/searchmoves), and searchmoves filtering. This
# harness pins the bestmove of each such mode against a committed golden so the
# iterative_deepening port can be validated beyond the signature gate.
#
# Time management is wall-clock non-deterministic and is deliberately NOT covered
# here -- only deterministic modes (node/depth-limited) are gated.
#
# Usage: search_modes.sh <stockfish-bin> <golden-file> [check|update]
# Run with cwd = src/ so the external NNUE net resolves.
set -u

BIN="$1"
GOLDEN="$2"
MODE="${3:-check}"

SP='position startpos'
KIWI='position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 10'
END='position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1'

run_test() {
    printf '%b\nquit\n' "$1" | "$BIN" 2>/dev/null | grep '^bestmove' | tr -d '\r'
}

emit() {
    printf 'nodes-startpos     %s\n' "$(run_test "$SP\ngo nodes 300000")"
    printf 'nodes-kiwipete     %s\n' "$(run_test "$KIWI\ngo nodes 300000")"
    printf 'nodes-endgame      %s\n' "$(run_test "$END\ngo nodes 500000")"
    printf 'depth-searchmoves  %s\n' "$(run_test "$SP\ngo depth 14 searchmoves d2d4 g1f3")"
    printf 'multipv3-startpos  %s\n' "$(run_test "setoption name MultiPV value 3\n$SP\ngo depth 12")"
    printf 'multipv4-kiwipete  %s\n' "$(run_test "setoption name MultiPV value 4\n$KIWI\ngo depth 11")"
}

live="$(emit)"

if printf '%s\n' "$live" | grep -qE '[[:space:]]$'; then
    echo "search-modes: a test produced no bestmove (engine crashed?)" >&2
    printf '%s\n' "$live" >&2
    exit 2
fi

if [ "$MODE" = "update" ]; then
    printf '%s\n' "$live" > "$GOLDEN"
    echo "search-modes: wrote golden ($(printf '%s\n' "$live" | grep -c .) modes)"
    exit 0
fi

if [ ! -f "$GOLDEN" ]; then
    echo "search-modes: golden missing: $GOLDEN (run the update step first)" >&2
    exit 2
fi

if diff_out="$(diff <(cat "$GOLDEN") <(printf '%s\n' "$live"))"; then
    echo "search-modes: OK (all deterministic non-bench modes match golden)"
    exit 0
fi

echo "search-modes: MISMATCH vs golden (< golden, > live):" >&2
printf '%s\n' "$diff_out" >&2
exit 1
