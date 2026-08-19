#!/usr/bin/env bash
# Watch the compiler REFUSE the mistakes the types were added to make unrepresentable.
#
# WHAT THIS PROVES. For each row: the wrong form does not compile AND fails with the
# error this repo's documentation quotes, and the right form still does. Nothing else.
#
# WHAT IT CANNOT SEE. Whether the type is worth its cost, whether the call sites use it,
# or whether some OTHER transposition is still expressible. It checks the claims that are
# written down, one snippet each.
#
# WHY IT EXISTS. docs/09-type-design.md states, in prose, that certain mistakes are now
# refused -- and that page has ALREADY BEEN WRONG about exactly that. It recorded the
# `statsUpdate` clamp as safe because the parameter is `comptime` ("the transposition is
# not even expressible"), and it was expressible: with a literal bonus both arguments are
# compile-time known, the swap type-checked, and the gravity curve reshaped with nothing
# refusing it. A type that is meant to make a mistake unrepresentable is an ASSUMPTION
# until something writes the mistake and the compiler is watched rejecting it.
#
# TWO-SIDED, AND THE TEXT IS PART OF IT. Every row checks the legal form too, so a file
# that simply stopped compiling -- a renamed decl, a moved module -- cannot score a pass.
# And the illegal side must match the EXPECTED MESSAGE, not merely fail: while this gate
# was being written, a row phrased as `export fn probe(k: ScoreKind)` failed with
# "parameter of type ... not allowed in function with calling convention 'x86_64_sysv'",
# which is a rig fault that reads exactly like a detection. A second row compiled CLEANLY
# when it should have failed, because `comptime { _ = f; }` references a function without
# analysing its body, so the switch inside was never checked. Exit codes alone score both
# of those wrong.
#
# HOW THE SNIPPETS REACH THE CODE. Each is written next to the module it tests and built
# with `zig build-obj`, so a RELATIVE import resolves with no module wiring. Zig is lazy
# about the named-module imports at the top of those files, so a snippet touching one
# declaration never resolves the rest of the graph. The limit of that trick is real and is
# recorded below: a module whose tested declaration pulls in the graph cannot be reached
# this way.
#
# Exit codes:  0 every row refused and permitted what it should   1 a row did not   2 rig fault
set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2
command -v zig >/dev/null || { echo "type-refusal: SKIPPED -- no zig on PATH" >&2; exit 2; }

TMPOBJ=$(mktemp -u "${TMPDIR:-/tmp}/zfish-typerefusal-XXXXXX.o")
PROBE=""
cleanup() { [ -n "$PROBE" ] && rm -f "$PROBE"; rm -f "$TMPOBJ"; }
trap cleanup EXIT

PASSED=0
FAILED=0

# Compile a snippet placed in $1, echo its diagnostics, return the compiler's exit code.
compile_in() {
    local dir=$1 body=$2
    PROBE="$dir/zz_type_refusal_probe.zig"
    printf '%s' "$body" > "$PROBE"
    local out rc
    out=$(zig build-obj -femit-bin="$TMPOBJ" "$PROBE" 2>&1)
    rc=$?
    rm -f "$PROBE"
    PROBE=""
    printf '%s' "$out"
    return $rc
}

# name | dir | expected error substring | illegal | legal
check_row() {
    local name=$1 dir=$2 want=$3 illegal=$4 legal=$5
    local out rc ok=1

    out=$(compile_in "$dir" "$illegal"); rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  FAIL   $name -- the WRONG form compiled; the type refuses nothing"
        ok=0
    elif ! printf '%s' "$out" | grep -qF "$want"; then
        echo "  FAIL   $name -- refused, but not for the stated reason"
        echo "           want: $want"
        printf '%s\n' "$out" | grep -E "error:" | sed 's/^/           got : /' | head -2
        ok=0
    fi

    out=$(compile_in "$dir" "$legal"); rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  FAIL   $name -- the LEGAL form does not compile; the row proves nothing"
        printf '%s\n' "$out" | grep -E "error:" | sed 's/^/           /' | head -2
        ok=0
    fi

    if [ "$ok" -eq 1 ]; then
        echo "  ok     $name"
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
}

echo "type-refusal: writing each mistake and watching the compiler reject it"
echo

# --- HistLimit: the clamp this page was once wrong about ----------------------
check_row "histlimit-transpose  (bonus <-> limit)" src/engine/search \
    "expected type 'i32', found 'search_common.HistLimit'" \
'const sc = @import("search_common.zig");
export fn probe() void {
    var e: i16 = 0;
    sc.statsUpdate(&e, sc.capture_history_limit, 892);
}
' \
'const sc = @import("search_common.zig");
export fn probe() void {
    var e: i16 = 0;
    sc.statsUpdate(&e, 892, sc.capture_history_limit);
}
'

check_row "histlimit-bare       (a raw 10692)   " src/engine/search \
    "expected type 'search_common.HistLimit', found 'comptime_int'" \
'const sc = @import("search_common.zig");
export fn probe() void {
    var e: i16 = 0;
    sc.statsUpdate(&e, 892, 10692);
}
' \
'const sc = @import("search_common.zig");
export fn probe() void {
    var e: i16 = 0;
    sc.statsUpdate(&e, 892, sc.capture_history_limit);
}
'

# --- NodeKind: three states, and no fourth ------------------------------------
check_row "nodekind-fourth      (a non-PV root)" src/engine/search \
    "has no member named 'non_pv_root'" \
'const st = @import("search_types.zig");
export fn probe() u8 {
    const k: st.NodeKind = .non_pv_root;
    return @intFromEnum(k);
}
' \
'const st = @import("search_types.zig");
export fn probe() u8 {
    const k: st.NodeKind = .root;
    return @intFromEnum(k);
}
'

# --- ScoreKind: the boundary type that must be switched on exhaustively -------
check_row "scorekind-exhaustive (a missing arm)" src/engine/board \
    "switch must handle all possibilities" \
'const s = @import("score.zig");
export fn probe(x: u8) u8 {
    const k: s.ScoreKind = @enumFromInt(x);
    return switch (k) {
        .non_decisive => 0,
        .mate => 1,
    };
}
' \
'const s = @import("score.zig");
export fn probe(x: u8) u8 {
    const k: s.ScoreKind = @enumFromInt(x);
    return switch (k) {
        .non_decisive => 0,
        .mate => 1,
        .tablebase => 2,
    };
}
'

# NOT A ROW, and the omission is stated rather than left as silence:
# `qsearchImpl`'s `@compileError("quiescence is never entered at the root")` cannot be
# reached this way. Analysing it means analysing search_qsearch.zig, which imports
# worker_layout, search_ctx and a dozen more BY MODULE NAME -- so a relative-import
# snippet fails with "no module named 'worker_layout'", which is a rig fault, not a
# refusal. The adjacent property it guards is covered by the unit test
# "NodeKind: a root is a PV node, and quiescence is never a root" in search_types.zig.

echo
if [ "$FAILED" -eq 0 ]; then
    echo "type-refusal: OK ($PASSED row(s): each wrong form refused, each right form built)"
else
    echo "type-refusal: FINDINGS ($PASSED ok, $FAILED failed)"
fi
exit $((FAILED > 0 ? 1 : 0))
