#!/usr/bin/env bash
# Full-output golden gate (Stage-7 7.0a).
#
# The differential output_parity.sh diffs the bench info+bestmove text of the
# default (Zig) binary against the legacy (C++) oracle. Stage 7 deletes the
# oracle, so this variant pins the SAME stripped output against a committed
# golden instead -- preserving the strongest info-line regression catcher
# (depth, seldepth, multipv, score, nodes, hashfull, tbhits, pv, bound, wdl)
# without the legacy binary. The golden is captured (7.0a) while the oracle
# still exists, and output_parity.sh proves golden == oracle in the same build.
#
# Non-deterministic fields (time, nps) are stripped; the strip pipeline is
# byte-identical to output_parity.sh so the golden matches the oracle output.
#
# Usage:
#   output_parity_golden.sh <stockfish-bin> <golden-file> [check|update]
#     check  (default): diff the live stripped output against <golden-file>;
#                        exit non-zero on divergence.
#     update          : (re)write <golden-file> from the live run.
#
# Run with cwd = src/ so the external NNUE net resolves.
set -u

BIN="$1"
GOLDEN="$2"
MODE="${3:-check}"

run() {
    # prints the bench info+bestmove lines with volatile fields (time, nps) removed
    "$BIN" bench 2>&1 \
        | grep -E '^(info depth|bestmove)' \
        | sed -E 's/ time [0-9]+//; s/ nps [0-9]+//' \
        | tr -d '\r'
}

live="$(run)"

if [ -z "$live" ]; then
    echo "output-golden: binary produced no info output (crash?)" >&2
    exit 2
fi

if [ "$MODE" = "update" ]; then
    printf '%s\n' "$live" > "$GOLDEN"
    echo "output-golden: wrote golden ($(printf '%s\n' "$live" | grep -c .) info/bestmove lines)"
    exit 0
fi

if [ ! -f "$GOLDEN" ]; then
    echo "output-golden: golden file missing: $GOLDEN (run the update step first)" >&2
    exit 2
fi

if diff_out="$(diff <(cat "$GOLDEN") <(printf '%s\n' "$live"))"; then
    echo "output-golden: OK ($(printf '%s\n' "$live" | grep -c .) info/bestmove lines match golden)"
    exit 0
fi

echo "output-golden: MISMATCH vs golden (< golden, > live):" >&2
printf '%s\n' "$diff_out" | head -40 >&2
exit 1
