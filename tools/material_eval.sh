#!/usr/bin/env bash
# Spine isolation: build BOTH engines with the NNUE evaluation replaced by material count.
#
# WHY. A zfish/upstream ratio measured with the real eval blends two things: how fast the search
# spine walks the tree, and how fast the NNUE evaluates a leaf. Stubbing the eval to material in
# both engines removes the second, so what is left is the spine.
#
# THE TRAP THIS TOOL EXISTS TO PREVENT. An earlier attempt at this experiment concluded "the
# spine, not the NNUE, is the gap" and was WRONG, because the two engines were stubbed
# differently and therefore searched different trees -- a different workload on each side, so
# every ratio was meaningless. The stub is only valid if both engines score every position
# identically. This script gates on exactly that: it benches both and REFUSES to report unless
# the two node counts are equal. Do not paper over a mismatch by "just comparing anyway".
#
# The stubbed node count is NOT 2884956 and is not supposed to be -- a different eval is a
# different tree. The anchor does not apply here; the equality of the two sides is the anchor.
#
# Usage:  material_eval.sh [ARCH...]        # default: all four measured tiers
#         BENCH="16 1 13" material_eval.sh x86-64-avx2
#         OUT=/path/to/bin material_eval.sh
#
# Leaves the oracle worktree clean on exit, including on failure: the patch is reverted AND the
# stubbed binary it produced is deleted, so nothing can silently measure against a stub.
set -euo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
ORACLE_DIR="${ZFISH_ORACLE_DIR:-/home/usr00/_git/.zfish-upstream-oracle}"
PATCH="$REPO/tools/upstream/material_eval.patch"
BENCH="${BENCH:-16 1 13}"
OUT="${OUT:-$REPO/zig-out/material-eval}"
ARCHES=("$@")
[ ${#ARCHES[@]} -eq 0 ] && ARCHES=(x86-64-sse41-popcnt x86-64-avx2 x86-64-vnni512 x86-64-avx512icl)

[ -f "$PATCH" ] || { echo "material-eval: missing $PATCH" >&2; exit 2; }

# Put the oracle SOURCE back between builds. Called mid-loop, so it deliberately leaves the
# build state alone: the patched and unpatched builds of one arch share a stamp, and make
# rebuilds just evaluate.cpp between them.
cleanup() { git -C "$ORACLE_DIR" checkout -- src/evaluate.cpp 2>/dev/null || true; }

# Leave nothing usable-but-wrong behind, however this exits.
#
# Reverting the source is NOT enough, and believing it was is the bug this function exists to
# close: the last thing the loop builds is a STUBBED oracle, and it stays on disk benching a
# number that is not the anchor. Every in-repo consumer routes through upstream_oracle.sh and
# would rebuild -- but the stamp still matches, so upstream_oracle.sh sees a current build and
# does nothing, and anyone running $ORACLE_DIR/src/stockfish by hand gets the stub. It cost a
# wrong NNUE ratio here; only perf_counters' node-count guard caught it.
#
# So delete the binary AND the stamp. The next build is then a clean one, and in the window
# before it there is nothing to accidentally measure -- a missing binary fails loudly, a
# stubbed one does not.
finish() {
    cleanup
    rm -f "$ORACLE_DIR/src/stockfish" "$ORACLE_DIR/src/.zfish_oracle_stamp"
}
trap finish EXIT

mkdir -p "$OUT"
nodes_of() { grep -oE 'Nodes searched[ :]+[0-9]+' | grep -oE '[0-9]+$'; }

rc=0
printf '%-24s %14s %14s %s\n' "arch" "zfish nodes" "oracle nodes" "same tree?"
for arch in "${ARCHES[@]}"; do
    short="${arch#x86-64-}"; short="${short%-popcnt}"

    zig build -Dstub-eval "-Darch=$arch" -p "$OUT/z-$short" >"$OUT/z-$short.log" 2>&1 \
        || { echo "material-eval: zfish build failed for $arch (see $OUT/z-$short.log)" >&2; exit 1; }
    cp "$OUT/z-$short/bin/stockfish" "$OUT/zfish_$short"

    cleanup
    git -C "$ORACLE_DIR" apply "$PATCH"
    ARCH="$arch" bash "$REPO/tools/upstream_oracle.sh" >"$OUT/o-$short.log" 2>&1 \
        || { echo "material-eval: oracle build failed for $arch (see $OUT/o-$short.log)" >&2; exit 1; }
    cp "$ORACLE_DIR/src/stockfish" "$OUT/oracle_$short"
    cleanup

    zn=$(cd "$REPO/resources" && "$OUT/zfish_$short" bench $BENCH 2>&1 | nodes_of || true)
    on=$(cd "$REPO/resources" && "$OUT/oracle_$short" bench $BENCH 2>&1 | nodes_of || true)

    if [ -z "$zn" ] || [ -z "$on" ]; then
        printf '%-24s %14s %14s %s\n' "$arch" "${zn:-?}" "${on:-?}" "NO NODE COUNT -- run from a cwd with the net"
        rc=1
    elif [ "$zn" != "$on" ]; then
        printf '%-24s %14s %14s %s\n' "$arch" "$zn" "$on" "*** MISMATCH -- STUBS DISAGREE, DO NOT MEASURE ***"
        rc=1
    else
        printf '%-24s %14s %14s %s\n' "$arch" "$zn" "$on" "yes"
    fi
done

if [ $rc -ne 0 ]; then
    echo >&2
    echo "material-eval: FAIL -- at least one tier does not search one tree. The two stubs must" >&2
    echo "  score every position identically; fix them before quoting any ratio from these binaries." >&2
    exit 1
fi
echo
echo "material-eval: OK -- every tier searches ONE tree; binaries in $OUT (md5-pin them before measuring)."
echo "material-eval: the oracle worktree's own binary was REMOVED (it was the stubbed one);"
echo "material-eval: the next tools/upstream_oracle.sh rebuilds it pristine."
