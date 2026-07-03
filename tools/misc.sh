#!/usr/bin/env bash
# UCI misc-command differential/golden harness (REPORT-11 E1.2, coverage audit tail).
#
# Covers the deterministic non-search UCI commands that no other gate touches:
#   d     -> Fen / Key (Zobrist) / Checkers      (Position::fen + gives_check + the do_move hash)
#   flip  -> Position::flip (zfish_position_flip_fen)
# These are niche but exercise frozen-Position read paths the cut touches; bench
# never runs them. Pins Fen+Key+Checkers across a few positions so they are
# verified once the oracle is deleted at TU=0.
#
# Usage: misc.sh <stockfish-bin> <golden-file> [check|update|emit]   (cwd = src/)
set -u

BIN="$1"
GOLDEN="$2"
MODE="${3:-check}"

SP='position startpos'
KIWI='position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1'
CHECK='position fen rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3'

run_cmds() {
    # $1 = the UCI command sequence (before the final d/quit)
    printf '%b\nquit\n' "$1" | "$BIN" 2>/dev/null | grep -iE '^Fen:|^Key:|^Checkers:' | tr -d '\r'
}

emit() {
    printf '== startpos d ==\n%s\n'        "$(run_cmds "$SP\nd")"
    printf '== startpos flip d ==\n%s\n'   "$(run_cmds "$SP\nflip\nd")"
    printf '== kiwipete d ==\n%s\n'        "$(run_cmds "$KIWI\nd")"
    printf '== kiwipete flip d ==\n%s\n'   "$(run_cmds "$KIWI\nflip\nd")"
    printf '== in-check d ==\n%s\n'        "$(run_cmds "$CHECK\nd")"
}

live="$(emit)"

if [ "$(printf '%s\n' "$live" | grep -c '^Key:')" -ne 5 ]; then
    echo "misc: expected 5 Key lines, got $(printf '%s\n' "$live" | grep -c '^Key:') (crash?)" >&2
    printf '%s\n' "$live" >&2
    exit 2
fi

if [ "$MODE" = "emit" ]; then
    printf '%s\n' "$live"
    exit 0
fi

if [ "$MODE" = "update" ]; then
    printf '%s\n' "$live" > "$GOLDEN"
    echo "misc: wrote golden (5 command sequences)"
    exit 0
fi

if [ ! -f "$GOLDEN" ]; then
    echo "misc: golden missing: $GOLDEN (run the update step first)" >&2
    exit 2
fi

if diff_out="$(diff <(cat "$GOLDEN") <(printf '%s\n' "$live"))"; then
    echo "misc: OK (d/flip Fen+Key+Checkers match golden)"
    exit 0
fi

echo "misc: MISMATCH vs golden (< golden, > live):" >&2
printf '%s\n' "$diff_out" | head -40 >&2
exit 1
