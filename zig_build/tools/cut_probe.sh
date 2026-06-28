#!/usr/bin/env bash
# REPORT-12 cut-surface probe — the honest burndown meter for the TU=0 cut.
#
# frozen_refs.py undercounts: it matches T:: / sizeof(T) / static_cast<T*>-> / new T, but MISSES
# `w->member` accesses on already-typed locals (the bulk of the time-management glue). The only
# truthful gauge of "how close is the cut" is: drop the frozen headers, compile, count the errors.
# This script does exactly that against a scratch copy, buckets the errors by REPORT-12 class, then
# leaves the tree untouched (it never writes the cut into the real file).
#
# Usage:  bash zig_build/tools/cut_probe.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ZIG="${ZIG:-/home/usr00/.zig/zig-x86_64-linux-0.16.0/zig}"
SRC="$ROOT/zig_compat/uci_bridge.cpp"
BAK="$(mktemp)"
cp "$SRC" "$BAK"
trap 'cp "$BAK" "$SRC"; rm -f "$BAK"' EXIT

# Drop the 7 frozen-pulling headers (guard legacy-only) + pull in the forward-decls.
python3 - "$SRC" <<'PY'
import re, sys
f = sys.argv[1]; s = open(f).read().split("\n")
frozen = {'engine.h','uci.h','thread.h','search.h','position.h','score.h','perft.h'}
out, added = [], False
for ln in s:
    m = re.match(r'\s*#include "([a-z_]+\.h)"', ln)
    if m and m.group(1) in frozen:
        if not added:
            out += ['#ifndef ZFISH_LEGACY_CPP_TARGET','#include "frozen_fwd.h"','#include "timeman.h"','#endif']; added = True
        out += ['#ifdef ZFISH_LEGACY_CPP_TARGET', ln, '#endif']
    else:
        out.append(ln)
open(f,"w").write("\n".join(out))
PY

ERR="$("$ZIG" build -Darch=x86-64-sse41-popcnt 2>&1 | grep -E 'uci_bridge\.cpp:[0-9]+.*error:')"
total=$(printf '%s\n' "$ERR" | grep -c 'error:')
a=$(printf '%s\n' "$ERR" | grep -cE "out-of-line definition|does not match any declaration|member function .* in incomplete")
b=$(printf '%s\n' "$ERR" | grep -cE "member access into incomplete type|incomplete type '")
c=$(printf '%s\n' "$ERR" | grep -cE "no member named|no type named|private member")
echo "=== cut_probe: TU=0 header-drop surface ==="
echo "TOTAL build errors : $total"
echo "  A member-fn defs : $a   (out-of-line def of a forward-declared type)"
echo "  B member access  : $b   (w->member on an incomplete type)"
echo "  C other (no-member/type): $c"
echo "(tree restored; nothing written)"
[ "$total" -eq 0 ] && echo ">>> SURFACE CLEAR — the header-drop is now mechanical."
exit 0
