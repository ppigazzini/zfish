#!/usr/bin/env bash
# Docs rot gate.
#
# The invariant: docs/ must not make a claim the tree contradicts. Docs are accurate when
# written and rot where the code moves under them, so this checks the three rot classes that
# a machine can settle. Everything else -- whether the prose is TRUE -- still needs a reader.
#
# Every check here was paid for. A hostile audit of docs/ found, in one session, that:
#   * a file path in prose pointed at a module that had been split away;
#   * the bench anchor was quoted as 2067208 in five places while build.zig said 2792255
#     (the anchor MOVES on every bench-moving upstream sync; PROMPT.md warns about exactly
#     this and its own sibling doc had drifted anyway);
#   * link targets broke silently when the doc set was renumbered.
# Each is mechanical. Each shipped anyway, because nothing checked.
#
# NOT checked, deliberately: whether a sentence is true. "numa_context is a never-dereferenced
# stub handle" parses fine, links fine, and was false for weeks. No grep finds that -- only
# reading the code does. This gate buys the cheap half so a reviewer can spend attention on
# the expensive half.
#
# Usage:  docs_lint.sh            # from the repo root
# Exit:   0 all checks pass, 1 a doc contradicts the tree.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
fail=0

# --- 1. every internal link resolves -------------------------------------------------------
# Renaming the set 0-N -> 00-N rewrote 124 references; a typo in any of them is a dead link a
# reader hits and we never do.
broken=0
for f in docs/*.md README.md CONTRIBUTING.md AGENTS.md; do
    [ -e "$f" ] || continue
    dir=$(dirname "$f")
    while IFS= read -r target; do
        case "$target" in http*|"") continue ;; esac
        path="${target%%#*}"                       # strip the #anchor
        [ -n "$path" ] || continue                 # a bare #anchor is intra-file
        [ -e "$dir/$path" ] || [ -e "$path" ] || {
            echo "docs-lint: BROKEN LINK  $f -> $target"
            broken=$((broken + 1))
        }
    done < <(grep -oE '\]\([^)]+\)' "$f" | sed 's/^](//; s/)$//')
done
[ "$broken" -eq 0 ] || fail=1

# --- 2. every repo path named in prose exists ----------------------------------------------
# Docs name owners constantly ("src/shell/uci.zig", "tools/parity_harness.zig"). A split or a
# rename silently invalidates the reference; the prose still reads plausibly.
missing=0
while IFS= read -r p; do
    [ -e "$p" ] || { echo "docs-lint: DEAD PATH    $p (named in a shipped doc, not in the tree)"; missing=$((missing + 1)); }
done < <(grep -ohE '`(src|tools)/[A-Za-z0-9_/.-]+\.(zig|sh|py|golden)`' docs/*.md AGENTS.md \
         | tr -d '`' | sort -u)
[ "$missing" -eq 0 ] || fail=1

# --- 3. the bench anchor matches build.zig -------------------------------------------------
# The anchor MOVES per upstream sync. build.zig is the single source (signature_reference);
# any 7-digit node count in docs/ that is not it is a doc quoting a dead anchor.
anchor=$(grep -oE 'signature_ref orelse "[0-9]+"' build.zig | grep -oE '[0-9]+')
if [ -z "$anchor" ]; then
    echo "docs-lint: cannot read signature_reference from build.zig"
    fail=1
else
    stale=0
    while IFS=: read -r file num; do
        [ "$num" = "$anchor" ] && continue
        echo "docs-lint: STALE ANCHOR $file quotes $num, build.zig says $anchor"
        stale=$((stale + 1))
    done < <(grep -oHE '\b2[0-9]{6}\b' docs/*.md AGENTS.md | sed 's/:\(.*\)$/:\1/')
    [ "$stale" -eq 0 ] || fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "docs-lint: OK ($(ls docs/*.md | wc -l | tr -d ' ') docs + AGENTS.md: links resolve, paths exist, anchor == $anchor)"
else
    echo "docs-lint: FAIL -- a doc contradicts the tree (see above)."
fi
exit "$fail"
