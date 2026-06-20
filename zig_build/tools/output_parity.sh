#!/usr/bin/env bash
# Full-output differential gate (M5).
#
# The signature / search-parity / search-modes gates pin node counts, scores,
# and bestmoves, but NOT the UCI info-line text. `bench` drives a real
# fixed-depth search across its position set and emits one `info depth ...` line
# per iteration through SearchManager::pv, so diffing that text between the
# default (Zig) binary and the legacy (C++) oracle is the regression catcher for
# porting the pv / search-driver output path to Zig: while pv is C++ in both the
# diff is trivially equal; once pv is Zig in the default only (legacy keeps the
# C++ pv behind ZFISH_LEGACY_CPP_TARGET) the diff verifies the Zig port verbatim.
#
# Non-deterministic fields (time, nps) are stripped; everything else on the line
# (depth, seldepth, multipv, score, nodes, hashfull, tbhits, pv, bound, wdl) is
# compared exactly.
#
# Usage: output_parity.sh <default-bin> <legacy-bin>; run with cwd = src/ so the
# external NNUE net resolves.
set -u

DEFAULT_BIN="$1"
LEGACY_BIN="$2"

run() {
    # $1 = binary; prints the bench info+bestmove lines with volatile fields removed
    "$1" bench 2>&1 \
        | grep -E '^(info depth|bestmove)' \
        | sed -E 's/ time [0-9]+//; s/ nps [0-9]+//' \
        | tr -d '\r'
}

default_out="$(run "$DEFAULT_BIN")"
legacy_out="$(run "$LEGACY_BIN")"

if [ -z "$default_out" ]; then
    echo "output-parity: default binary produced no info output (crash?)" >&2
    exit 2
fi
if [ -z "$legacy_out" ]; then
    echo "output-parity: legacy binary produced no info output (crash?)" >&2
    exit 2
fi

if [ "$default_out" = "$legacy_out" ]; then
    echo "output-parity: OK ($(printf '%s\n' "$default_out" | grep -c .) info/bestmove lines match)"
    exit 0
fi

echo "output-parity: MISMATCH (< legacy, > default):" >&2
diff <(printf '%s\n' "$legacy_out") <(printf '%s\n' "$default_out") | head -40 >&2
exit 1
