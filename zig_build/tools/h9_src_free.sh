#!/usr/bin/env bash
# H9 — src-free / TU=0 structural gate (REPORT-11 E1.4).
#
# The definition-of-done for TU=0: the default binary must contain ZERO C++
# translation units. The robust structural signal is the symbol table — every C++
# Stockfish-namespace symbol (mangled `Stockfish::…`) and the libc++ runtime
# (`std::` / `__cxa_*`) comes from uci_bridge.cpp + the src/ headers it includes;
# the native Zig runtime exports only `zfish_*` + opaque pointers. When the last
# C++ TU is deleted (E3/E4), the C++ symbols and the statically-linked libc++
# vanish, and this gate flips to OK. It also re-asserts bench 2336177 so a TU=0
# binary that lost behaviour cannot pass.
#
# FAILS ON PURPOSE until the cut lands — it documents the target and guards
# against regression. It is wired into the `parity` aggregate only at E4.3.
#
# Usage: h9_src_free.sh <stockfish-bin>   (run with cwd = src/ so bench finds the net)
set -u

BIN="$1"

# Guard: a stripped binary would show 0 C++ symbols for the WRONG reason → false pass.
total="$(nm "$BIN" 2>/dev/null | wc -l)"
if [ "$total" -lt 100 ]; then
    echo "h9: cannot verify — binary exposes only $total symbols (stripped?). Build non-stripped." >&2
    exit 2
fi

# AUTHORITATIVE structural signal (cwd-independent — nm reads the binary by absolute path): a C++
# TU compiled into the default exe leaves Stockfish-namespace + libc++ runtime symbols behind.
cpp_sf="$(nm "$BIN" 2>/dev/null | grep -c 'Stockfish')"          # C++ Stockfish-namespace symbols
cpp_std="$(nm "$BIN" 2>/dev/null | grep -cE '_ZNSt|_ZSt|__cxa_|__cxx')"  # libc++ runtime

# Informational file-level cross-check, resolved from the script's own location (the gate runs with
# cwd=src/, so relative paths would be wrong). NOT part of the pass condition — the symbol table is.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
src_cpp="$(ls "$ROOT"/src/*.cpp 2>/dev/null | wc -l)"
bridge="$( [ -f "$ROOT/zig_compat/uci_bridge.cpp" ] && echo present || echo absent )"

sig="$("$BIN" bench 2>&1 | sed -n 's/^Nodes searched  *: *\([0-9][0-9]*\).*/\1/p' | head -1)"

echo "h9: C++ Stockfish symbols=$cpp_sf  libc++ runtime symbols=$cpp_std  (info: src/*.cpp=$src_cpp  uci_bridge.cpp=$bridge)  bench=$sig"

if [ "$cpp_sf" -eq 0 ] && [ "$cpp_std" -eq 0 ] && [ "$sig" = "2336177" ]; then
    echo "h9: OK — TU=0 reached (no C++ Stockfish/libc++ symbols in the default binary; bench 2336177)"
    exit 0
fi

echo "h9: NOT YET src-free — expected to FAIL until the TU=0 cut (E3/E4) removes the last C++ TU." >&2
exit 1
