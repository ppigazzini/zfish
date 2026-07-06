#!/usr/bin/env bash
# Net-placement helper (REPORT-13 Annex A6).
#
# The .nnue is gitignored and per-worktree, so a synced `refactor` won't run unless the target net is
# present in EVERY worktree's src/. This resolves the net name for a commit (its EvalFileDefaultName),
# locates the file (the pristine oracle's src/, which `make` already fetched), and copies it into every
# git worktree's src/.
#
# Usage:  upstream_net.sh [sha]      # sha defaults to UPSTREAM_TARGET
set -euo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
TOOLS="$REPO/tools"
ORACLE_DIR="${ZFISH_ORACLE_DIR:-/home/usr00/_git/.zfish-upstream-oracle}"
SHA="${1:-$(cat "$TOOLS/upstream/UPSTREAM_TARGET")}"

# net name lives in the commit's evaluate.h
NET="$(git -C "$REPO" show "$SHA:src/evaluate.h" | sed -n 's/.*EvalFileDefaultName "\([^"]*\)".*/\1/p' | head -1)"
[ -n "$NET" ] || { echo "upstream-net: could not read EvalFileDefaultName from $SHA:src/evaluate.h" >&2; exit 1; }
echo "upstream-net: target net for $(git -C "$REPO" rev-parse --short "$SHA") is $NET"

# source copy: prefer the oracle's src/, else any worktree that already has it
SRC=""
for cand in "$ORACLE_DIR/src/$NET" $(git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p' | sed "s|\$|/src/$NET|"); do
    [ -f "$cand" ] && { SRC="$cand"; break; }
done
if [ -z "$SRC" ]; then
    echo "upstream-net: $NET not found locally. Build the pristine oracle to fetch it:" >&2
    echo "  ZFISH_ORACLE_DIR=$ORACLE_DIR $TOOLS/upstream_oracle.sh $SHA" >&2
    exit 1
fi
echo "upstream-net: source = $SRC ($(du -h "$SRC" | cut -f1))"

placed=0
while IFS= read -r wt; do
    [ -d "$wt/src" ] || continue
    dst="$wt/src/$NET"
    if [ ! -f "$dst" ]; then
        cp "$SRC" "$dst"; echo "  placed -> $dst"; placed=$((placed+1))
    fi
done < <(git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p')
echo "upstream-net: done ($placed worktree(s) updated; net is gitignored, not committed)."
