#!/usr/bin/env bash
# Perft differential gate: default (Zig) vs legacy (C++) oracle (REPORT-11 E1.1).
#
# Runs the perft.sh emit (sorted divide counts + totals for the standard CPW
# positions + an FRC castling position) on BOTH binaries and asserts they are
# byte-identical. This certifies the native do_move/undo_move/movegen against the
# C++ oracle while the oracle still exists -- the run that makes perft.golden
# trustworthy before TU=0 deletes the oracle (REPORT-11 §2.2 / E1.3).
#
# Usage: perft_parity.sh <default-bin> <legacy-bin>
# Run with cwd = src/ so the external NNUE net resolves.
set -u

DEFAULT_BIN="$1"
LEGACY_BIN="$2"
HERE="$(dirname "$0")"

default_out="$(bash "$HERE/perft.sh" "$DEFAULT_BIN" /dev/null emit)" || {
    echo "perft-parity: default binary perft emit failed (crash?)" >&2; exit 2; }
legacy_out="$(bash "$HERE/perft.sh" "$LEGACY_BIN" /dev/null emit)" || {
    echo "perft-parity: legacy binary perft emit failed (crash?)" >&2; exit 2; }

if diff_out="$(diff <(printf '%s\n' "$legacy_out") <(printf '%s\n' "$default_out"))"; then
    echo "perft-parity: OK (default == legacy: perft divide counts + totals identical)"
    exit 0
fi

echo "perft-parity: MISMATCH (< legacy, > default):" >&2
printf '%s\n' "$diff_out" | head -40 >&2
exit 1
