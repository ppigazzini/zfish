#!/usr/bin/env bash
# Docs rot gate.
#
# The invariant: docs/ must not make a claim the tree contradicts. Docs are accurate when
# written and rot where the code moves under them, so this checks the three rot classes that
# a machine can settle. Everything else -- whether the prose is TRUE -- still needs a reader.
#
# Every check here was paid for. A hostile audit of docs/ found, in one session, that:
#   * a file path in prose pointed at a module that had been split away;
#   * the bench anchor was quoted as 2067208 in five places while build.zig said something
#     else entirely (the anchor MOVES on every bench-moving upstream sync, and a doc that
#     pins it drifts -- so this sentence names the stale value only, never the live one);
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

# --- resolve a claim against the TREE, not this working directory ---------------------------
# `-e` answers "is the file HERE", which is not the question a doc asks -- a reader gets the
# tree. The two failure modes it produces are opposite and both silent: a file left behind by
# a rename is green here and DEAD in a fresh clone (../rfish took a red CI run on exactly
# that), and a path .gitignore deliberately excludes can never be green anywhere.
#
# Ask git instead, and exempt an ignored path: one the repository decided not to carry is a
# doc naming the tool that WRITES it, not a claim about a tracked file. State the hole that
# leaves rather than hide it -- a dead IGNORED path stays unchecked. What this closes is the
# "present in my checkout, absent from the tree" class, which reports OK instead of erroring.
#
# Take the index ONCE into a set and answer from it: this runs against every link target and
# every path claim, and a `git` per lookup costs ~2.5s of a 6s gate. The two git calls below
# are the miss path only -- `--error-unmatch` normalises the pathspec, which is what resolves
# a link written `docs/../AGENTS.md` that a literal set lookup cannot match.
#
# Outside a checkout (a tarball export) there is no tree to ask. Fall back to the filesystem
# and SAY so: a check that quietly changes what it proves is a skip reported as a pass.
declare -A tracked_set=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tree_backed=1
    while IFS= read -r tracked_path; do
        tracked_set["$tracked_path"]=1
    done < <(git ls-files)
else
    tree_backed=0
    echo "docs-lint: NOT A GIT CHECKOUT -- path claims fall back to the filesystem."
fi

in_tree() {
    if [ "$tree_backed" -eq 0 ]; then
        [ -e "$1" ]
        return
    fi
    [ -n "${tracked_set[$1]+set}" ] && return 0
    git ls-files --error-unmatch -- "$1" >/dev/null 2>&1 && return 0
    git check-ignore -q -- "$1"
}

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
        in_tree "$dir/$path" || in_tree "$path" || {
            echo "docs-lint: BROKEN LINK  $f -> $target"
            broken=$((broken + 1))
        }
    done < <(grep -oE '\]\([^)]+\)' "$f" | sed 's/^](//; s/)$//')
done
[ "$broken" -eq 0 ] || fail=1

# --- 2. every repo path named in prose exists ----------------------------------------------
# Docs name owners constantly ("src/shell/uci.zig", "tools/parity_harness.zig"). A split or a
# rename silently invalidates the reference; the prose still reads plausibly.
#
# The subject is every directory this repository OWNS and every extension it writes -- a claim
# about `docs/`, `build/` or `.github/` rots exactly like one about `src/`, and 09-tooling-ci
# names a workflow file per CI lane. `.cpp`/`.h` are excluded ON PURPOSE: `src/syzygy/
# tbprobe.cpp` is UPSTREAM's path, a namespace these pages reference without owning, the same
# exclusion check 4 makes for `_mm*` intrinsics. Scanning the two root pages check 4 already
# reads (README, CONTRIBUTING) costs nothing and closes the same class there.
missing=0
path_claims=$(grep -ohE '`(src|tools|docs|build|\.github)/[A-Za-z0-9_/.-]+\.(zig|sh|py|golden|md|yml|yaml|zon|tsv|json)`' \
              docs/*.md AGENTS.md README.md CONTRIBUTING.md | tr -d '`' | sort -u)
while IFS= read -r p; do
    [ -n "$p" ] || continue
    in_tree "$p" || { echo "docs-lint: DEAD PATH    $p (named in a shipped doc, not in the tree)"; missing=$((missing + 1)); }
done <<< "$path_claims"
[ "$missing" -eq 0 ] || fail=1

# Guard the EXTRACTION, not just its verdict -- check 5's lesson, which covered 6% of its
# subject while reporting OK. A typo in the regex above finds nothing and passes everything.
path_total=$(printf '%s\n' "$path_claims" | grep -c .)
if [ "$path_total" -lt 60 ]; then
    echo "docs-lint: only $path_total path claims found (expected ~98) -- the extraction lost"
    echo "docs-lint: its subject; the prose or the pattern changed shape. Refusing to report OK."
    fail=1
fi

# A CI lane is named by its FILE, and docs/09 names each one bare rather than by path, so the
# check above cannot see it. A renamed workflow leaves the lane table pointing at nothing.
badflow=0
while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    in_tree ".github/workflows/$wf" || {
        echo "docs-lint: DEAD WORKFLOW $wf (named in a shipped doc, not in .github/workflows/)"
        badflow=$((badflow + 1))
    }
done < <(grep -ohE '`[A-Za-z0-9_-]+\.(yml|yaml)`' docs/*.md AGENTS.md README.md CONTRIBUTING.md \
         | tr -d '`' | sort -u)
[ "$badflow" -eq 0 ] || fail=1

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

# The shipped tree must not reference __DEV. __DEV/ is internal and gitignored, so a clone has
# no such file: a shipped doc or source comment pointing there is a dangling reference for every
# reader outside this working copy. Duplicating the CONTENT is fine -- naming the location is not.
#
# SWEEP EVERY TRACKED FILE, not a hand-written list of places to look. This read
# `docs/ src/ tools/ README.md CONTRIBUTING.md AGENTS.md CLAUDE.md build.zig` -- so the whole
# `build/` package, all of `.github/`, and every other root file could name __DEV and still
# report clean. That is the shape of the bug this check exists for: the sibling port
# established the same rule, verified it by hand, and had it broken twice within days by
# commits that had no way to know, because the checker only read one class of file. A list of
# directories rots; the index does not.
#
# EXACTLY TWO FILES MAY NAME IT, and both are structural rather than a claim about the tree:
# `.gitignore` DECLARES the directory, and this script carries the pattern that finds it.
# Anything else is a dangling reference for every reader but its author. An untracked working
# copy is out of scope by construction, which is the point -- that directory is working state.
leak=0
if [ "$tree_backed" -eq 1 ]; then
    # Exempt the two files with a git PATHSPEC rather than filtering the results afterwards:
    # the exclusion is then applied by git against the same index it is searching, so it cannot
    # be defeated by a path spelled differently than the filter expects. (../mcfish's guard,
    # which converged on this same rule independently, uses exactly this form.)
    dev_hits="$(git grep -InE '__DEV|REPORT-[0-9]|4-PERFORMANCE-REFERENCES|00-CONTRACT|PROMPT\.md' \
        -- . ':!.gitignore' ':!tools/docs_lint.sh' 2>/dev/null | cut -d: -f1,2 | sort -u)"
    rc=$?
    # `git grep` exits 1 for "no matches" and >1 for a real error. Only the first is a clean
    # sweep -- an error reported as clean would be a check that had stopped checking.
    if [ "$rc" -gt 1 ]; then
        echo "docs-lint: the __DEV sweep could not read the index -- refusing to report it clean"
        fail=1
    else
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            echo "docs-lint: __DEV REFERENCE IN SHIPPED TREE $hit"
            leak=$((leak + 1))
        done <<<"$dev_hits"
    fi
else
    # Outside a checkout there is no index to sweep, but the rule still holds -- and the
    # previous version of this check ran on plain `grep -r`, so falling back to a SKIP here
    # would quietly drop coverage a tarball export used to have. Walk the filesystem instead
    # and say which subject was used: a check that changes what it proves must say so.
    echo "docs-lint: NOT A GIT CHECKOUT -- the __DEV sweep reads the filesystem, not the index."
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        echo "docs-lint: __DEV REFERENCE IN SHIPPED TREE $hit"
        leak=$((leak + 1))
    done < <(grep -rInE '__DEV|REPORT-[0-9]|4-PERFORMANCE-REFERENCES|00-CONTRACT|PROMPT\.md' \
        --exclude-dir=.git --exclude-dir=__DEV --exclude=.gitignore --exclude=docs_lint.sh . 2>/dev/null |
        cut -d: -f1,2 | sort -u || true)
fi
[ "$leak" -eq 0 ] || fail=1

# --- 4. every backticked identifier names something in the tree -----------------------------
# Prose names Zig symbols constantly. A rename or a deletion leaves the sentence reading
# plausibly while pointing at nothing -- 07-shell named `makeManager` for a whole session
# after the function was deleted, and checks 1-3 all passed over it.
#
# Read the code spans DIRECTLY. Do not filter the pages through any "strip noise" helper
# first: a helper that removes inline code spans leaves this check scanning nothing and
# passing everything, which is how the same gate failed its own negative test in the C port.
#
# Judge only IDENTIFIER-SHAPED tokens (snake_case, or camelCase with an inner capital), and
# only ones in zfish's own namespace. The exclusions are namespaces the tree deliberately
# names without defining:
#   _mm*/_tzcnt*/__builtin*  upstream's C++ intrinsics, in 08's translation dictionary
#   Zig std/builtin names    firstTrue, ReleaseSmall, async_limit, ... documented, not ours
#                            to define -- 09 has to name `async_limit` to explain why one
#                            `--fuzz` session cannot start every fuzz artifact
#   *_ci                     CI branch/ref names, not symbols
foreign='^(_mm|_tzcnt|_adds|_subs|__builtin)|^(firstTrue|lastTrue|countTrues|ReleaseSmall|ReleaseFast|ReleaseSafe|async_limit)$|_ci$'
unknown=0
while IFS= read -r tok; do
    printf '%s' "$tok" | grep -qE '_|[a-z][A-Z]' || continue      # identifier-shaped only
    printf '%s' "$tok" | grep -qE "$foreign" && continue          # foreign namespace
    # Exclude this file: its own comments name the examples, and a gate that finds its own
    # documentation passes on the very claim it exists to catch (verified: `makeManager` was
    # a live dead symbol and the first cut of this check reported clean because of it).
    grep -rqF --exclude=docs_lint.sh -- "$tok" src tools build.zig 2>/dev/null || {
        echo "docs-lint: DEAD SYMBOL  \`$tok\` (named in a shipped doc, defined nowhere in the tree)"
        unknown=$((unknown + 1))
    }
done < <(grep -ohE '`[A-Za-z_][A-Za-z0-9_]*`' docs/*.md AGENTS.md README.md CONTRIBUTING.md \
         | tr -d '`' | sort -u)
[ "$unknown" -eq 0 ] || fail=1

# --- 5. every build step is documented somewhere -------------------------------------------
# 09-tooling-ci's job is to say what each step proves. A step nothing mentions is a gate a
# contributor cannot find, which is the same as not having it.
# READ THE WHOLE FILE, NOT LINE BY LINE. build.zig writes most steps across three lines
#
#     const nodestime_step = b.step(
#         "nodestime",
#         "...",
#     );
#
# so a line-anchored grep saw the name only where it happened to share a line with
# `b.step(`. That was 5 steps of 77, and the 72 it skipped included 24 with no shipped
# mention at all -- this check reported OK for as long as it has existed while covering
# 6% of its subject. Collapse newlines first so the extraction sees every step.
#
# `<gate>-update` is covered by its BASE gate: the pairing is a documented convention
# ("Every golden gate is a pair", 09-tooling-ci.md), so 21 near-identical names do not each
# need their own prose. Requiring the base keeps that honest -- an update step whose gate
# nobody documented still fails.
undoc=0
while IFS= read -r step; do
    target="$step"
    case "$step" in
    *-update) target="${step%-update}" ;;
    esac
    grep -rqF -- "$target" docs/*.md AGENTS.md README.md CONTRIBUTING.md || {
        if [ "$target" = "$step" ]; then
            echo "docs-lint: UNDOCUMENTED STEP  \`zig build $step\` exists, no shipped page mentions it"
        else
            echo "docs-lint: UNDOCUMENTED STEP  \`zig build $step\` exists, and its base gate \`$target\` is undocumented too"
        fi
        undoc=$((undoc + 1))
    }
done < <({
    tr '\n' ' ' < build.zig | grep -oE 'b\.step\(\s*"[a-z0-9-]+"' | sed 's/.*"\(.*\)"/\1/'
    # The 21 golden gates are a TABLE now, not 21 hand-written b.step() calls, so their 42
    # names live here instead. Missing this file does not fail the gate -- it shrinks it,
    # silently, which is the same way the line-anchored grep above used to cover 6%.
    # Steps live in build.zig AND in the build/ package: tables in gates.zig /
    # structural.zig, plain b.step() calls in tests.zig. Scan both forms across both places
    # -- missing one does not fail this check, it SHRINKS it, which is how it once covered 6%.
    for f in build/*.zig; do
        [ -f "$f" ] || continue
        tr '\n' ' ' < "$f" | grep -oE 'b\.step\(\s*"[a-z0-9-]+"' | sed 's/.*"\(.*\)"/\1/'
        grep -oE '\.(step|update_step) = "[a-z0-9-]+"' "$f" | sed 's/.*"\(.*\)"/\1/'
    done
} | sort -u)
[ "$undoc" -eq 0 ] || fail=1

# Guard the EXTRACTION, not just its verdict. Every failure this check has had was a
# shrinking subject rather than a wrong answer, and a shrunk subject reports OK.
step_total=$( {
    tr '\n' ' ' < build.zig | grep -oE 'b\.step\(\s*"[a-z0-9-]+"' | sed 's/.*"\(.*\)"/\1/'
    # Steps live in build.zig AND in the build/ package: tables in gates.zig /
    # structural.zig, plain b.step() calls in tests.zig. Scan both forms across both places
    # -- missing one does not fail this check, it SHRINKS it, which is how it once covered 6%.
    for f in build/*.zig; do
        [ -f "$f" ] || continue
        tr '\n' ' ' < "$f" | grep -oE 'b\.step\(\s*"[a-z0-9-]+"' | sed 's/.*"\(.*\)"/\1/'
        grep -oE '\.(step|update_step) = "[a-z0-9-]+"' "$f" | sed 's/.*"\(.*\)"/\1/'
    done
} | sort -u | wc -l)
if [ "$step_total" -lt 70 ]; then
    echo "docs-lint: only $step_total build steps found (expected ~77) -- the extraction lost"
    echo "docs-lint: its subject; a step table moved or changed shape. Refusing to report OK."
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "docs-lint: OK ($(ls docs/*.md | wc -l | tr -d ' ') docs + AGENTS.md: links resolve, paths are in the tree, symbols and steps exist, anchor == $anchor, no __DEV refs)"
else
    echo "docs-lint: FAIL -- a doc contradicts the tree (see above)."
fi
exit "$fail"
