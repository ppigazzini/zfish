#!/usr/bin/env bash
# Steady-state upstream sync driver (REPORT-13 Annex A1 + A2).
#
# One command that answers "what do I need to do to follow upstream?": fetch, compute the behind-count
# from UPSTREAM_BASE, and print the tiered backlog + per-commit bench targets and Zig owner files.
#
# Usage:
#   upstream_sync.sh            # full report: behind-count + worklist + tiered backlog
#   upstream_sync.sh --check    # terse one-line behind-count (for a scheduled poll / cron / /loop)
#   upstream_sync.sh --no-fetch # skip `git fetch` (use already-fetched refs)
set -euo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
TOOLS="$REPO/tools"
CHECK=0
FETCH=1
for a in "$@"; do
    case "$a" in
        --check) CHECK=1 ;;
        --no-fetch) FETCH=0 ;;
    esac
done

[ "$FETCH" = 1 ] && git -C "$REPO" fetch upstream --quiet 2>/dev/null || true

BASE="$(cat "$TOOLS/upstream/UPSTREAM_BASE")"
HEAD_SHA="$(git -C "$REPO" rev-parse upstream/master)"
behind="$(git -C "$REPO" rev-list --count "$BASE..upstream/master")"

if [ "$CHECK" = 1 ]; then
    if [ "$behind" -eq 0 ]; then
        echo "upstream-sync: IN SYNC (base == upstream/master == $(git -C "$REPO" rev-parse --short "$HEAD_SHA"))"
    else
        echo "upstream-sync: $behind commit(s) behind -> $(git -C "$REPO" log -1 --format='%h %s' "$HEAD_SHA")"
    fi
    exit 0
fi

echo "=== upstream sync status ==="
echo "  base (last fully ported): $(git -C "$REPO" rev-parse --short "$BASE")"
echo "  upstream/master HEAD    : $(git -C "$REPO" log -1 --format='%h  %ci  %s' "$HEAD_SHA")"
echo "  behind                  : $behind commit(s)"
if [ "$behind" -eq 0 ]; then
    echo ""
    echo "  IN SYNC -- nothing to do."
    exit 0
fi

echo ""
echo "=== WORKLIST (bench-movers + NNUE-arch only -- the commits that actually need porting) ==="
UPSTREAM_BASE_OVERRIDE="$BASE" python3 "$TOOLS/upstream_router.py" --worklist || true

echo ""
echo "=== full tiered backlog (FORMULA = integer-semantics review per A4) ==="
UPSTREAM_BASE_OVERRIDE="$BASE" python3 "$TOOLS/upstream_router.py" --backlog || true

echo ""
echo "Next: port each worklist commit into its owner .zig, then  zig build signature  must equal its Bench."
echo "Verify the end state with  tools/upstream_parity.sh  (build the pristine oracle @ HEAD)."
