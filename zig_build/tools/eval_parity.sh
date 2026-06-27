#!/usr/bin/env bash
# Eval-trace differential gate: default (Zig) vs legacy (C++) oracle (REPORT-11 E1.2).
#
# Runs the eval.sh emit (deterministic NNUE trace block for several positions) on
# BOTH binaries and asserts they are byte-identical -- certifies the native
# eval-trace / network-ptr formatting path against the C++ oracle while it still
# exists, so eval.golden is trustworthy after TU=0 deletes the oracle.
#
# Usage: eval_parity.sh <default-bin> <legacy-bin>   (cwd = src/)
set -u

DEFAULT_BIN="$1"
LEGACY_BIN="$2"
HERE="$(dirname "$0")"

default_out="$(bash "$HERE/eval.sh" "$DEFAULT_BIN" /dev/null emit)" || {
    echo "eval-parity: default binary eval emit failed (crash?)" >&2; exit 2; }
legacy_out="$(bash "$HERE/eval.sh" "$LEGACY_BIN" /dev/null emit)" || {
    echo "eval-parity: legacy binary eval emit failed (crash?)" >&2; exit 2; }

if diff_out="$(diff <(printf '%s\n' "$legacy_out") <(printf '%s\n' "$default_out"))"; then
    echo "eval-parity: OK (default == legacy: NNUE trace block identical)"
    exit 0
fi

echo "eval-parity: MISMATCH (< legacy, > default):" >&2
printf '%s\n' "$diff_out" | head -40 >&2
exit 1
