#!/usr/bin/env bash
# Cross-version build-script gate: the version shims have ONE owner, and nothing else
# names a std.Build field that only one supported compiler has.
#
# WHY THIS EXISTS, AND WHY IT IS NOT PARANOIA. zfish targets Zig 0.17.0 and tracks Zig
# master in a non-blocking lane. `build/config.zig` owns every read of a std.Build field
# whose name a compiler release has changed -- the build root is `root: Cache.Path` today,
# and it was `build_root: Cache.Directory` one release ago -- so the rest of the build never
# has to know which compiler it is under.
#
# That works exactly as long as everyone CALLS the shim. Two sites did not: `lanes.zig`
# reached for `b.build_root.path` and `structural.zig` for `b.build_root.handle`, and
# both landed green under the compiler every contributor ran while the master lane was
# red from the commit that added them.
#
# The failure is worse than one broken step. A `std.Build` field break is a CONFIGURE
# error: `build()` never finishes, so EVERY step of that lane dies at once -- exe, test,
# fuzz, every arch tier -- and the log names a file nobody edited. There is no partial
# signal to read.
#
# So the rule is structural rather than advisory: outside `build/config.zig`, no build
# file may name `build_root` or `b.root`. The shim is the interface; this is what makes
# it one.
#
# The second list is the retired-API set, each with the spelling that replaced it: APIs a
# supported compiler removed, and APIs the current one deprecates, which it marks only in
# doc comments and which the next can delete. These are cheap to grep and expensive to find
# at a toolchain bump, and copying an older build snippet is how one comes back.
#
# Usage: build_version_lint.sh          (run from anywhere; resolves its own root)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OWNER="build/config.zig"

# The subject: the build script and its package. A miss here is SILENT -- an empty file
# list makes every scan below vacuous and the gate still exits 0 -- so the floor is
# load-bearing, exactly as in headless_lint.sh and docs_lint.sh.
mapfile -t FILES < <(cd "$ROOT" && ls build.zig build/*.zig 2>/dev/null)
FLOOR=8
if [ "${#FILES[@]}" -lt "$FLOOR" ]; then
    printf 'build-version-lint: RIG FAULT -- found %d build file(s), under the floor of %d;\n' \
        "${#FILES[@]}" "$FLOOR" >&2
    printf 'build-version-lint: a subject that shrank reports OK, so this refuses instead\n' >&2
    exit 2
fi
if [ ! -f "$ROOT/$OWNER" ]; then
    printf 'build-version-lint: RIG FAULT -- the shim owner %s is gone\n' "$OWNER" >&2
    exit 2
fi

fail=0

note() { printf '  %-22s %s\n' "$1" "$2"; }

# --- 1. the version-dependent fields, which only the owner may name -------------------
#
# Match a FIELD ACCESS (`b.build_root`, `.root.root_dir`), not the word, so a comment
# explaining the rule does not trip it. `# ` and `// ` lines are dropped first.
for f in "${FILES[@]}"; do
    [ "$f" = "$OWNER" ] && continue
    hits="$(sed 's://.*::' "$ROOT/$f" | grep -nE '\.build_root\b|\.root\.root_dir\b' || true)"
    [ -z "$hits" ] && continue
    while IFS= read -r line; do
        note "SHIM BYPASSED" "$f:${line%%:*} names a version-dependent std.Build field"
        fail=$((fail + 1))
    done <<< "$hits"
done

# --- 2. APIs a supported compiler removed or deprecates ------------------------------
#
# <pattern>|<what to use instead>. Each was paid for: see docs/08-idiomatic-zig.md.
RETIRED=(
    'b\.args|run.addPassthruArgs(), or a -D string option build() reads -- std.Build has no `b.args` since 0.17'
    'b\.pathFromRoot|config.repoPath(b, ...)'
    'b\.getInstallPath|run.addArtifactArg2(exe, .{}) -- the path is relative to the child cwd, so a script that cds must anchor it'
    'std\.meta\.Int|@Int(.unsigned, n) -- the builtin survives std renames'
    '\.add[A-Za-z]+Arg\(|the *Arg2 form, e.g. run.addFileArg2(path, .{}) -- 0.17 deprecates every path-taking add*Arg, and std marks only some'
    'runAllowFail|b.runFallible(argv, .{ ... }) -- deprecated in 0.17'
)
for entry in "${RETIRED[@]}"; do
    pat="${entry%%|*}"; fix="${entry#*|}"
    # A pattern grep cannot compile matches nothing, and the scan below reads that as clean:
    # refuse it. The entry splits on its FIRST `|`, so a pattern may not alternate with one.
    grep -qE -- "$pat" </dev/null 2>/dev/null
    if [ $? -eq 2 ]; then
        printf 'build-version-lint: RIG FAULT -- retired-API pattern does not compile: %s\n' "$pat" >&2
        exit 2
    fi
    for f in "${FILES[@]}"; do
        hits="$(sed 's://.*::' "$ROOT/$f" | grep -nE "$pat" || true)"
        [ -z "$hits" ] && continue
        while IFS= read -r line; do
            note "RETIRED API" "$f:${line%%:*} -> use $fix"
            fail=$((fail + 1))
        done <<< "$hits"
    done
done

if [ "$fail" -ne 0 ]; then
    printf 'build-version-lint: FAIL -- %d cross-version violation(s) above.\n' "$fail" >&2
    printf 'build-version-lint: these are CONFIGURE errors under a supported compiler, so they\n' >&2
    printf 'build-version-lint: take down every step of that lane at once, not just this one.\n' >&2
    exit 1
fi

printf 'build-version-lint: OK (%d build file(s); the version shims in %s have no bypass)\n' \
    "${#FILES[@]}" "$OWNER"
