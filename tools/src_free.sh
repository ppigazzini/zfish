#!/usr/bin/env bash
# Src-free / TU=0 structural gate.
#
# Definition-of-done for TU=0: the shipped binary contains ZERO C++ translation
# units. The robust structural signal is the symbol table — a C++ Stockfish TU
# leaves mangled `Stockfish::…` symbols and the statically-linked libc++ runtime
# (`std::` / `__cxa_*`) behind; the Zig runtime exports only `zfish_*` + opaque
# pointers. This gate is a permanent invariant: it guards against any C++ TU being
# reintroduced into the default binary. It also re-asserts the bench signature so a
# src-free binary that lost behaviour cannot pass.
#
# The bench reference tracks the current upstream sync (like the goldens); bump it
# alongside them on an upstream resync.
#
# Usage: src_free.sh <stockfish-bin>   (run with cwd = net/ so bench finds the net)
set -u

BIN="$1"

# Guard: a stripped binary would show 0 C++ symbols for the WRONG reason → false pass.
total="$(nm "$BIN" 2>/dev/null | wc -l)"
if [ "$total" -lt 100 ]; then
    echo "src-free: cannot verify — binary exposes only $total symbols (stripped?). Build non-stripped." >&2
    exit 2
fi

# AUTHORITATIVE structural signal (cwd-independent — nm reads the binary by absolute path): a C++
# TU compiled into the default exe leaves Stockfish-namespace + libc++ runtime symbols behind.
cpp_sf="$(nm "$BIN" 2>/dev/null | grep -c 'Stockfish')"          # C++ Stockfish-namespace symbols
cpp_std="$(nm "$BIN" 2>/dev/null | grep -cE '_ZNSt|_ZSt|__cxa_|__cxx')"  # libc++ runtime

sig="$("$BIN" bench 2>&1 | sed -n 's/^Nodes searched  *: *\([0-9][0-9]*\).*/\1/p' | head -1)"

echo "src-free: C++ Stockfish symbols=$cpp_sf  libc++ runtime symbols=$cpp_std  bench=$sig"

if [ "$cpp_sf" -eq 0 ] && [ "$cpp_std" -eq 0 ] && [ "$sig" = "2466447" ]; then
    echo "src-free: OK — src-free (no C++ Stockfish/libc++ symbols in the shipped binary; bench 2466447)"
    exit 0
fi

echo "src-free: REGRESSION — src-free invariant violated (want cpp_sf=0 cpp_std=0 bench=2466447)." >&2
exit 1
