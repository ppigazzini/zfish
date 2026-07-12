#!/usr/bin/env bash
# Headless-engine structural gate.
#
# The invariant: src/engine/ is a standalone chess library -- it may import only
# other engine/ modules, never a platform/ or shell/ module. When this passes with
# a zero baseline, the engine compiles, unit-tests, and fuzzes with no threading
# runtime, no UCI frontend, and no OS services attached: a deterministic
# search+eval library the platform runs and the shell drives.
#
# How it works: build.zig's module_specs table is the authoritative module ->
# source-path map. A module is engine / platform / shell by the src/<zone>/ prefix
# of its path. This resolves every `@import("name")` in an engine source file to
# its zone and reports each engine -> {platform, shell} up-edge.
#
# Baseline ratchet: the seams are injected one at a time, so the count only ever
# decreases. HEADLESS_BASELINE is the currently-allowed count; the gate FAILS if
# the real count exceeds it (a regression re-coupled the engine), and NUDGES if it
# drops below (lower the baseline). Target: 0.
#
# Usage: headless_lint.sh            (run from the repo root)
#        HEADLESS_BASELINE=N headless_lint.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build.zig"
BASELINE="${HEADLESS_BASELINE:-0}"

[ -f "$BUILD" ] || { echo "headless: cannot find build.zig at $BUILD" >&2; exit 2; }

# module name -> zone, from module_specs { .name = "x", .path = "src/<zone>/..." }.
declare -A ZONE
while IFS=$'\t' read -r name path; do
    case "$path" in
        src/engine/*)   ZONE["$name"]=engine ;;
        src/platform/*) ZONE["$name"]=platform ;;
        src/shell/*)    ZONE["$name"]=shell ;;
        *)              ZONE["$name"]=root ;;
    esac
done < <(grep -oE '\.name = "[a-z_]+", \.path = "[^"]+"' "$BUILD" \
         | sed -E 's/\.name = "([a-z_]+)", \.path = "([^"]+)"/\1\t\2/')

# Scan every engine source file for imports that resolve to a down-zone module.
violations=0
tmp="$(mktemp)"
while IFS= read -r f; do
    while IFS= read -r key; do
        z="${ZONE[$key]:-}"
        if [ "$z" = platform ] || [ "$z" = shell ]; then
            printf '  %s -> %s (%s)\n' "${f#"$ROOT"/src/engine/}" "$key" "$z" >> "$tmp"
            violations=$((violations + 1))
        fi
    done < <(grep -oE '@import\("[a-z_]+"\)' "$f" | sed -E 's/@import\("([a-z_]+)"\)/\1/' | sort -u)
done < <(find "$ROOT/src/engine" -name '*.zig' | sort)

if [ "$violations" -gt 0 ]; then
    echo "headless: engine -> platform/shell up-edges:"
    sort "$tmp"
fi
rm -f "$tmp"
echo "headless: $violations engine->platform/shell up-edges (baseline $BASELINE)"

if [ "$violations" -gt "$BASELINE" ]; then
    echo "headless: REGRESSION -- up-edges rose above the baseline; the engine re-coupled to platform/shell." >&2
    exit 1
fi
if [ "$violations" -lt "$BASELINE" ]; then
    echo "headless: NUDGE -- $violations < baseline $BASELINE; lower HEADLESS_BASELINE (a seam was severed)."
fi
if [ "$violations" -eq 0 ]; then
    echo "headless: OK -- engine/ imports only engine/ (standalone library invariant holds)"
fi
exit 0
