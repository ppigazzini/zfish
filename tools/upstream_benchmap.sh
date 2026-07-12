#!/usr/bin/env bash
# Per-commit bench-signature map.
#
# Every upstream commit message carries a "Bench: NNNN" line -- a free, exact, per-commit bit-exact
# checkpoint. This emits  <short-sha>\t<bench>\t<subject>  for UPSTREAM_BASE..UPSTREAM_TARGET, oldest
# first, so the resync can replay commits one at a time and assert our `signature` == that commit's Bench.
#
# Usage:  upstream_benchmap.sh [<base>] [<target>]
#   defaults: tools/upstream/UPSTREAM_BASE .. tools/upstream/UPSTREAM_TARGET
set -euo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
BASE="${1:-$(cat "$REPO/tools/upstream/UPSTREAM_BASE")}"
TARGET="${2:-$(cat "$REPO/tools/upstream/UPSTREAM_TARGET")}"

printf '%-10s  %-9s  %s\n' "SHA" "BENCH" "SUBJECT"
n=0
for sha in $(git -C "$REPO" log --reverse --no-merges --format=%H "$BASE..$TARGET"); do
    subj="$(git -C "$REPO" log -1 --format=%s "$sha")"
    bench="$(git -C "$REPO" log -1 --format=%b "$sha" | grep -oiE 'Bench: ?[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
    printf '%-10s  %-9s  %s\n' "$(git -C "$REPO" rev-parse --short "$sha")" "${bench:-—}" "$subj"
    n=$((n+1))
done
echo "# $n commits  ($(git -C "$REPO" rev-parse --short "$BASE")..$(git -C "$REPO" rev-parse --short "$TARGET"))" >&2
