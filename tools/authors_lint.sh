#!/usr/bin/env bash
# AUTHORS attribution gate.
#
# `AUTHORS` is upstream Stockfish's own file, carried verbatim. That is a licence
# obligation, not housekeeping: zfish reproduces upstream's search and evaluation, so it
# is a derived work and the attribution travels with it (docs/11-references.md).
#
# "Verbatim" is a CLAIM, and a claim nothing checks is one that rots. It did: by the
# 2edd935b resync the file was fifteen names short, accumulated across several syncs --
# including the one upstream 22dfb404 added in the window being ported, because the commit
# that ported the rest of 22dfb404 read the source files and not this one. A sibling port
# found it by diff, which is the whole idea here.
#
# Compare against the PINNED upstream tree (tools/upstream/UPSTREAM_BASE), not a fetched
# branch: the file must match the commit this port claims to be synced to, and a moving
# reference would go red on every upstream push rather than on a real omission.
#
# This needs the upstream remote's git objects, which a plain checkout of origin does not
# carry -- the same reason `upstream-map` sits outside the parity aggregate. The weekly
# upstream-check workflow fetches the remote and dispatches it there. A missing object is
# a REFUSAL, never a skip: a gate that cannot see its reference has not passed.
#
# Usage: authors_lint.sh [repo-root]
set -u

# Derive the root from this script's own location, not from the cwd: the build step runs it
# from wherever `zig build` was invoked.
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BASE_FILE="$ROOT/tools/upstream/UPSTREAM_BASE"

[ -r "$BASE_FILE" ] || { echo "authors-lint: FAIL -- no $BASE_FILE" >&2; exit 1; }
BASE="$(tr -d '[:space:]' < "$BASE_FILE")"

if ! git -C "$ROOT" cat-file -e "$BASE:AUTHORS" 2>/dev/null; then
    echo "authors-lint: FAIL -- upstream object $BASE:AUTHORS is not in this clone." >&2
    echo "authors-lint: fetch the upstream remote first (git fetch upstream master)." >&2
    echo "authors-lint: a gate that cannot see its reference has NOT passed." >&2
    exit 1
fi

if diff_out="$(diff "$ROOT/AUTHORS" <(git -C "$ROOT" show "$BASE:AUTHORS"))"; then
    lines="$(wc -l < "$ROOT/AUTHORS")"
    echo "authors-lint: OK (AUTHORS is upstream@${BASE:0:8}'s file verbatim, $lines lines)"
    exit 0
fi

missing="$(printf '%s\n' "$diff_out" | grep -c '^>' || true)"
extra="$(printf '%s\n' "$diff_out" | grep -c '^<' || true)"
echo "authors-lint: FAIL -- AUTHORS differs from upstream@${BASE:0:8} ($missing line(s) missing, $extra extra)" >&2
printf '%s\n' "$diff_out" | head -20 >&2
echo "authors-lint: refresh it: git show $BASE:AUTHORS > AUTHORS" >&2
exit 1
