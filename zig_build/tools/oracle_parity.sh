#!/usr/bin/env bash
# Differential oracle gate (M5).
#
# The default `stockfish` target is the Zig-owned runtime; `stockfish-legacy-cpp`
# compiles the first-party C++ owners (timeman/evaluate/movepick/tt/thread/
# tbprobe) as the behavioral oracle. This gate runs `bench` on BOTH and asserts
# their signatures are identical -- a single automated check that the Zig owns
# still match the C++ oracle at the whole-engine level.
#
# Usage: oracle_parity.sh <default-bin> <legacy-bin>
# Run with cwd = src/ so the external NNUE net resolves.
set -u

DEFAULT_BIN="$1"
LEGACY_BIN="$2"

sig() {
    # $1 = binary; prints the bench signature (Nodes searched) or empty on failure
    "$1" bench 2>&1 | sed -n 's/^Nodes searched  *: *\([0-9][0-9]*\).*/\1/p' | head -1
}

default_sig="$(sig "$DEFAULT_BIN")"
legacy_sig="$(sig "$LEGACY_BIN")"

if [ -z "$default_sig" ]; then
    echo "oracle-parity: default binary produced no signature (crash?)" >&2
    exit 2
fi
if [ -z "$legacy_sig" ]; then
    echo "oracle-parity: legacy binary produced no signature (crash?)" >&2
    exit 2
fi

if [ "$default_sig" = "$legacy_sig" ]; then
    echo "oracle-parity: OK (default == legacy: $default_sig)"
    exit 0
fi

echo "oracle-parity: MISMATCH (default=$default_sig legacy=$legacy_sig)" >&2
exit 1
