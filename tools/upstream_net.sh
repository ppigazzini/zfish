#!/usr/bin/env bash
# Net-placement helper.
#
# The .nnue is gitignored and per-worktree, so a synced worktree won't run unless the target net is
# present in it. This resolves the net name for a commit (its EvalFileDefaultName), locates the file
# (the shared oracle's nets/, which its build filled), and copies it into every git worktree's
# resources/.
#
# RESOURCES/, NOT SRC/. zfish loads the net as a runtime input from the cwd (NNUE_EMBEDDING_OFF), and
# every gate sets that cwd to resources/ -- so a net in src/ is 91 MB that nothing ever reads, and the
# worktree still will not run. This placed into src/ until 2026-08-04: the pre-migration location,
# left behind because no lane invoked this script and nothing else could notice. It is the reason
# tools_smoke.sh exists.
#
# Usage:  upstream_net.sh [sha]      # sha defaults to UPSTREAM_TARGET
set -euo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
TOOLS="$REPO/tools"
ORACLE_DIR="$("$TOOLS/upstream/upstream_oracle.sh" --dir)"
SHA="${1:-$(cat "$TOOLS/upstream/UPSTREAM_TARGET")}"

# net name lives in the commit's evaluate.h
NET="$(git -C "$REPO" show "$SHA:src/evaluate.h" | sed -n 's/.*EvalFileDefaultName "\([^"]*\)".*/\1/p' | head -1)"
[ -n "$NET" ] || { echo "upstream-net: could not read EvalFileDefaultName from $SHA:src/evaluate.h" >&2; exit 1; }
echo "upstream-net: target net for $(git -C "$REPO" rev-parse --short "$SHA") is $NET"

# source copy: prefer the oracle's nets/, else any worktree that already has it
SRC=""
for cand in "$ORACLE_DIR/nets/$NET" $(git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p' | sed "s|\$|/src/$NET|"); do
    [ -f "$cand" ] && { SRC="$cand"; break; }
done
if [ -z "$SRC" ]; then
    echo "upstream-net: $NET not found locally. Build the pristine oracle to fetch it:" >&2
    echo "  $TOOLS/upstream/upstream_oracle.sh $SHA" >&2
    exit 1
fi
echo "upstream-net: source = $SRC ($(du -h "$SRC" | cut -f1))"

placed=0
while IFS= read -r wt; do
    # Only zfish worktrees have a resources/ to fill.
    [ -d "$wt/src/engine" ] || continue
    mkdir -p "$wt/resources"
    dst="$wt/resources/$NET"
    if [ ! -f "$dst" ]; then
        cp "$SRC" "$dst"; echo "  placed -> $dst"; placed=$((placed+1))
    fi
done < <(git -C "$REPO" worktree list --porcelain | sed -n 's/^worktree //p')
echo "upstream-net: done ($placed worktree(s) updated; net is gitignored, not committed)."
