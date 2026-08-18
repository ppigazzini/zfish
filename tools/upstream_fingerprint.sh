#!/usr/bin/env bash
# Call-count fingerprint: assert zfish CALLS what upstream calls, as often.
#
# Profiles both engines under callgrind on ONE tree and holds every group in
# tools/fingerprint_groups.tsv to equality. A call-count divergence is an ALGORITHM bug and
# outranks any cost finding -- see that file for what this catches that the value gates
# cannot, and for the rules on adding a row.
#
# WHY CALL COUNTS AND NOT COST. A call count is inlining-immune: it does not care how the
# callee was reached, which is what lets a Zig tree be compared against a C++ one at all,
# where any cost claim has to argue attribution first. And callgrind SIMULATES rather than
# samples, so the result is deterministic -- a loaded box cannot flap it, unlike every
# cycles reading in this repo.
#
# It is ~50x slow, so it stays OUT of `zig build parity` and runs in the weekly upstream
# lane, which already builds the oracle.
#
# Usage:
#   upstream_fingerprint.sh                  # bench 16 1 8, sse41 both sides
#   BENCH="16 1 9" upstream_fingerprint.sh
#   ARCH=x86-64-avx2 upstream_fingerprint.sh
set -uo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
# No ORACLE_DIR here: this script reaches the oracle through upstream_oracle.sh below,
# which resolves ZFISH_ORACLE_DIR itself. A copy of that line sat here unread, looking
# like a knob that did nothing.
# NOT `GROUPS`: that is a bash built-in array of the caller's group IDs, and assigning to it
# is silently ignored -- the script then reported "missing 1000", the primary gid.
GROUPS_FILE="$REPO/tools/fingerprint_groups.tsv"
BENCH="${BENCH:-16 1 8}"
# sse41 by default: callgrind SIGILLs on avx512, and the call SEQUENCE is arch-independent
# by construction -- every tier searches the same tree, which the bench signature pins.
ARCH="${ARCH:-x86-64-sse41-popcnt}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v valgrind >/dev/null || { echo "fingerprint: valgrind not found" >&2; exit 2; }
[ -f "$GROUPS_FILE" ] || { echo "fingerprint: missing $GROUPS_FILE" >&2; exit 2; }

( cd "$REPO" && zig build "-Darch=$ARCH" ) >/dev/null 2>&1 \
    || { echo "fingerprint: zfish build failed for $ARCH" >&2; exit 2; }
ORACLE_BIN="$(ARCH="$ARCH" bash "$REPO/tools/upstream_oracle.sh")" \
    || { echo "fingerprint: oracle build failed" >&2; exit 2; }

echo "fingerprint: profiling both engines under callgrind (bench $BENCH, $ARCH) -- this is slow"
nodes_of() { grep -oE 'Nodes searched[ :]+[0-9]+' | grep -oE '[0-9]+$' | head -1; }
zn=$( cd "$REPO/resources" && valgrind --tool=callgrind --callgrind-out-file="$WORK/zf.out" \
      "$REPO/zig-out/bin/stockfish" bench $BENCH 2>&1 | nodes_of )
sn=$( cd "$REPO/resources" && valgrind --tool=callgrind --callgrind-out-file="$WORK/sf.out" \
      "$ORACLE_BIN" bench $BENCH 2>&1 | nodes_of )

# Assert ONE TREE first. Different trees are different workloads, and every row below would
# be noise dressed up as a divergence.
if [ -z "$zn" ] || [ -z "$sn" ] || [ "$zn" != "$sn" ]; then
    echo "fingerprint: REFUSING -- the two engines did not search one tree" >&2
    echo "fingerprint:   zfish ${zn:-<none>}   upstream ${sn:-<none>}" >&2
    exit 2
fi
echo "fingerprint: both engines search $zn nodes on bench $BENCH"

# Build the --group arguments from the table, skipping comments and blanks.
args=()
while IFS=$'\t' read -r name regex; do
    case "$name" in ''|\#*) continue ;; esac
    [ -z "${regex:-}" ] && continue
    args+=(--group "$name=$regex")
done < "$GROUPS_FILE"
[ "${#args[@]}" -eq 0 ] && { echo "fingerprint: no groups in $GROUPS_FILE" >&2; exit 2; }

out="$(python3 "$REPO/tools/perf_fingerprint.py" compare "$WORK/zf.out" "$WORK/sf.out" --calls "${args[@]}" 2>&1)"
rc=$?
printf '%s\n' "$out"
if [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -qE "DIFFERS|MISS"; then
    echo "" >&2
    echo "fingerprint: FAIL -- zfish does not call what upstream calls, as often." >&2
    echo "fingerprint: A call-count divergence is an ALGORITHM bug: the two engines reach the" >&2
    echo "fingerprint: same node count by different means, and no value gate here can see it." >&2
    echo "fingerprint: A MISS means the regex matched nothing on one side -- fix the row in" >&2
    echo "fingerprint: $GROUPS_FILE, do not delete the check." >&2
    exit 1
fi
echo ""
echo "fingerprint: OK -- every group EXACT; zfish runs upstream's call sequence"
