#!/usr/bin/env bash
# Eval-trace differential/golden harness (REPORT-11 E1.2).
#
# The `eval` command runs traceEvalEngine -> buildNnueTrace: the full NNUE forward
# pass printed as the per-bucket Material/Positional/Total table + the NNUE/Final
# evaluation lines. bench covers the eval VALUE (the signature is eval-sensitive)
# but NOT this trace-formatting path, which also routes through zfish_engine_
# network_ptr + the accumulator-cache trace. This gate pins the deterministic
# trace block for several positions so the formatting/network-ptr path is
# verified once the oracle is deleted at TU=0 (REPORT-11 §2.2 coverage audit).
#
# The block is captured from "NNUE network contributions" through "Final
# evaluation" (inclusive) so the per-commit version banner + the net info-string
# (which follow it) are excluded -- only deterministic numeric content remains.
#
# Usage: eval.sh <stockfish-bin> <golden-file> [check|update|emit]
# Run with cwd = src/ so the external NNUE net resolves.
set -u

BIN="$1"
GOLDEN="$2"
MODE="${3:-check}"

SP='position startpos'
KIWI='position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1'
END='position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1'
MID='position fen r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/3P1N2/PPP2PPP/RNBQK2R w KQkq - 0 5'

run_eval() {
    # $1 = position cmd; prints the deterministic NNUE trace block only.
    printf '%b\neval\nquit\n' "$1" | "$BIN" 2>&1 | tr -d '\r' \
        | awk '/NNUE network contributions/{f=1} f{print} /^Final evaluation/{f=0}'
}

emit() {
    printf '== startpos ==\n%s\n' "$(run_eval "$SP")"
    printf '== kiwipete ==\n%s\n' "$(run_eval "$KIWI")"
    printf '== endgame ==\n%s\n'  "$(run_eval "$END")"
    printf '== midgame ==\n%s\n'  "$(run_eval "$MID")"
}

live="$(emit)"

if [ "$(printf '%s\n' "$live" | grep -c '^Final evaluation')" -ne 4 ]; then
    echo "eval: expected 4 'Final evaluation' lines, got $(printf '%s\n' "$live" | grep -c '^Final evaluation') (crash?)" >&2
    printf '%s\n' "$live" >&2
    exit 2
fi

if [ "$MODE" = "emit" ]; then
    printf '%s\n' "$live"
    exit 0
fi

if [ "$MODE" = "update" ]; then
    printf '%s\n' "$live" > "$GOLDEN"
    echo "eval: wrote golden (4 positions)"
    exit 0
fi

if [ ! -f "$GOLDEN" ]; then
    echo "eval: golden missing: $GOLDEN (run the update step first)" >&2
    exit 2
fi

if diff_out="$(diff <(cat "$GOLDEN") <(printf '%s\n' "$live"))"; then
    echo "eval: OK (4 positions; NNUE trace block matches golden)"
    exit 0
fi

echo "eval: MISMATCH vs golden (< golden, > live):" >&2
printf '%s\n' "$diff_out" | head -40 >&2
exit 1
