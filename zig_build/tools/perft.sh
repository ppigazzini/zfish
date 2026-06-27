#!/usr/bin/env bash
# Perft differential/golden harness (REPORT-11 E1.1).
#
# `go perft N` is the ONLY exerciser of Position::do_move/undo_move + the full
# legal movegen + the UCI move formatter that had NO gate before this. Plain
# bench does not run perft; search-modes only checks bestmoves. This harness pins
# the per-root-move divide counts AND the total node count of the standard perft
# positions (en passant, castling, promotion, checks, pins, FRC castling) so that
# the do_move/undo_move/movegen paths are verified -- critical once the legacy
# oracle (and oracle-parity) is deleted at TU=0 and the golden becomes the sole
# reference (REPORT-11 §2.2).
#
# The divide lines are SORTED so the check is the SET of {move: subtree-count},
# independent of movegen emission order (robust for default-vs-legacy parity).
#
# Usage: perft.sh <stockfish-bin> <golden-file> [check|update|emit]
#   check  (default): diff live emit against <golden-file>; non-zero on divergence
#   update          : (re)write <golden-file> from the live run
#   emit            : print the live emit only (used by perft_parity.sh)
# Run with cwd = src/ so the external NNUE net resolves (perft itself needs no net,
# but the engine still loads it at startup).
set -u

BIN="$1"
GOLDEN="$2"
MODE="${3:-check}"

# Standard perft suite (CPW positions) + a chess960 castling position. Depths are
# chosen to exercise every move type while staying fast (each well under a second).
SP='position startpos'
KIWI='position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1'
POS3='position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1'
POS4='position fen r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1'
POS5='position fen rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8'
POS6='position fen r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10'
FRC='position fen nrkrbbqn/pppppppp/8/8/8/8/PPPPPPPP/NRKRBBQN w KQkq - 0 1'

run_perft() {
    # $1 = position cmd, $2 = depth; prints sorted divide lines + the total.
    local out
    out="$(printf '%b\ngo perft %s\nquit\n' "$1" "$2" | "$BIN" 2>/dev/null | tr -d '\r')"
    printf '%s\n' "$out" | grep -E '^[a-h][1-8][a-h][1-8][qrbnQRBN]?: [0-9]+' | sort
    printf '%s\n' "$out" | grep -E '^Nodes searched'
}

emit() {
    printf '== startpos d5 ==\n%s\n'  "$(run_perft "$SP"   5)"
    printf '== kiwipete d4 ==\n%s\n'  "$(run_perft "$KIWI" 4)"
    printf '== pos3 d6 ==\n%s\n'      "$(run_perft "$POS3" 6)"
    printf '== pos4 d4 ==\n%s\n'      "$(run_perft "$POS4" 4)"
    printf '== pos5 d4 ==\n%s\n'      "$(run_perft "$POS5" 4)"
    printf '== pos6 d4 ==\n%s\n'      "$(run_perft "$POS6" 4)"
    printf '== frc960 d4 ==\n%s\n'    "$(setoption_frc "$FRC" 4)"
}

setoption_frc() {
    # FRC needs UCI_Chess960 enabled; emit it before the position.
    local out
    out="$(printf 'setoption name UCI_Chess960 value true\n%b\ngo perft %s\nquit\n' "$1" "$2" \
        | "$BIN" 2>/dev/null | tr -d '\r')"
    printf '%s\n' "$out" | grep -E '^[a-h][1-8][a-h][1-8][qrbnQRBN]?: [0-9]+' | sort
    printf '%s\n' "$out" | grep -E '^Nodes searched'
}

live="$(emit)"

# Sanity: every position must produce a non-zero total.
if [ "$(printf '%s\n' "$live" | grep -c '^Nodes searched')" -ne 7 ]; then
    echo "perft: expected 7 totals, got $(printf '%s\n' "$live" | grep -c '^Nodes searched') (engine crashed?)" >&2
    printf '%s\n' "$live" >&2
    exit 2
fi

if [ "$MODE" = "emit" ]; then
    printf '%s\n' "$live"
    exit 0
fi

if [ "$MODE" = "update" ]; then
    printf '%s\n' "$live" > "$GOLDEN"
    echo "perft: wrote golden ($(printf '%s\n' "$live" | grep -c '^Nodes searched') positions)"
    exit 0
fi

if [ ! -f "$GOLDEN" ]; then
    echo "perft: golden missing: $GOLDEN (run the update step first)" >&2
    exit 2
fi

if diff_out="$(diff <(cat "$GOLDEN") <(printf '%s\n' "$live"))"; then
    echo "perft: OK (7 standard + FRC positions; divide counts + totals match golden)"
    exit 0
fi

echo "perft: MISMATCH vs golden (< golden, > live):" >&2
printf '%s\n' "$diff_out" | head -40 >&2
exit 1
