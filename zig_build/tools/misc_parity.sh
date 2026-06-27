#!/usr/bin/env bash
# UCI misc-command differential gate: default (Zig) vs legacy (C++) (REPORT-11 E1.2).
# Runs the misc.sh emit (d/flip Fen+Key+Checkers) on both binaries and asserts
# byte-identical -- certifies the native fen/flip/key/checkers paths against the
# oracle so misc.golden is trustworthy after TU=0.
#
# Usage: misc_parity.sh <default-bin> <legacy-bin>   (cwd = src/)
set -u

DEFAULT_BIN="$1"
LEGACY_BIN="$2"
HERE="$(dirname "$0")"

default_out="$(bash "$HERE/misc.sh" "$DEFAULT_BIN" /dev/null emit)" || {
    echo "misc-parity: default binary misc emit failed (crash?)" >&2; exit 2; }
legacy_out="$(bash "$HERE/misc.sh" "$LEGACY_BIN" /dev/null emit)" || {
    echo "misc-parity: legacy binary misc emit failed (crash?)" >&2; exit 2; }

if diff_out="$(diff <(printf '%s\n' "$legacy_out") <(printf '%s\n' "$default_out"))"; then
    echo "misc-parity: OK (default == legacy: d/flip Fen+Key+Checkers identical)"
    exit 0
fi

echo "misc-parity: MISMATCH (< legacy, > default):" >&2
printf '%s\n' "$diff_out" | head -40 >&2
exit 1
