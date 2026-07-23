#!/usr/bin/env bash
# Pristine upstream oracle.
#
# Builds VANILLA upstream Stockfish at a given sha into a detached git worktree, decoupled from this
# fork's src/ edits, and prints the resulting binary path. This is the binary-to-binary reference for the
# upstream resync: bump the sha, rebuild, and diff our native build against it (see upstream_parity.sh).
#
# Unlike the in-tree `stockfish-legacy-cpp` oracle (which compiles the fork-MODIFIED src/), this oracle
# is exactly what upstream ships at <sha> -- so "track upstream" is a one-line checkout, not a rebase of
# fork edits.
#
# Usage:  upstream_oracle.sh [<sha>]        # sha defaults to tools/upstream/UPSTREAM_TARGET
#         ARCH=... ZFISH_ORACLE_DIR=... ORACLE_COMP=gcc    # overridable
#   --verify   after building, run bench and assert it equals the commit's own "Bench: NNNN" line
#
# The oracle compiles with ZIG C++ (tools/zigcxx) unless ORACLE_COMP=gcc is set
# explicitly: every ratio against it must compare source/codegen on the SAME
# LLVM backend zfish uses. A gcc oracle measures gcc (+7.4% instructions on
# identical source, measured) -- reach for it only to study gcc itself.
set -euo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
ORACLE_DIR="${ZFISH_ORACLE_DIR:-/home/usr00/_git/.zfish-upstream-oracle}"
ARCH="${ARCH:-x86-64-sse41-popcnt}"
ORACLE_COMP="${ORACLE_COMP:-zigcxx}"

VERIFY=0
SHA_ARG=""
for a in "$@"; do
    case "$a" in
        --verify) VERIFY=1 ;;
        *) SHA_ARG="$a" ;;
    esac
done
SHA_REF="${SHA_ARG:-$(cat "$REPO/tools/upstream/UPSTREAM_TARGET")}"
SHA="$(git -C "$REPO" rev-parse "$SHA_REF")"

# (re)point the worktree at SHA -- reuse it if it exists (avoids re-downloading the 90MB net needlessly).
# Only check out when the worktree is not already at SHA: a force-checkout rewrites the source files
# (bumping their mtimes) and defeats make's incremental build, turning the steady-state fast check into a
# full ~11s rebuild. Skipping it when already at SHA leaves mtimes intact, so `make build` is a no-op and
# the gate costs only the bench (~2s) -- the fast in-repo check, with zero vendored C++.
if git -C "$REPO" worktree list --porcelain | grep -qx "worktree $ORACLE_DIR"; then
    if [ "$(git -C "$ORACLE_DIR" rev-parse HEAD 2>/dev/null || echo none)" != "$SHA" ]; then
        git -C "$ORACLE_DIR" checkout --detach -f "$SHA" >/dev/null 2>&1
    fi
else
    rm -rf "$ORACLE_DIR"
    git -C "$REPO" worktree add --detach "$ORACLE_DIR" "$SHA" >/dev/null
fi

echo "upstream-oracle: building vanilla Stockfish @ $(git -C "$REPO" rev-parse --short "$SHA") (ARCH=$ARCH)" >&2
if [ "$ORACLE_COMP" = "gcc" ]; then
    COMP_ARGS=(COMP=gcc)
else
    COMP_ARGS=(COMP=clang COMPCXX="$REPO/tools/zigcxx")
fi
# Object files from a different compiler (or ARCH) do not link -- clean when the
# stamp disagrees, keep the incremental fast path when it matches.
STAMP="$ORACLE_DIR/src/.zfish_oracle_stamp"
WANT_STAMP="$ORACLE_COMP $ARCH"
if [ "$(cat "$STAMP" 2>/dev/null)" != "$WANT_STAMP" ]; then
    make -C "$ORACLE_DIR/src" clean >/dev/null 2>&1 || true
    printf '%s' "$WANT_STAMP" >"$STAMP"
fi
make -C "$ORACLE_DIR/src" -j build ARCH="$ARCH" "${COMP_ARGS[@]}" >/tmp/upstream_oracle_build.log 2>&1 || {
    echo "upstream-oracle: BUILD FAILED -- tail of /tmp/upstream_oracle_build.log:" >&2
    tail -20 /tmp/upstream_oracle_build.log >&2
    exit 1
}
BIN="$ORACLE_DIR/src/stockfish"

if [ "$VERIFY" = 1 ]; then
    want="$(git -C "$REPO" log -1 --format=%b "$SHA" | grep -oiE 'Bench: ?[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
    got="$("$BIN" bench 2>&1 | sed -n 's/^Nodes searched  *: *\([0-9][0-9]*\).*/\1/p' | head -1)"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
        echo "upstream-oracle: BENCH MISMATCH (commit says $want, binary produced $got)" >&2
        exit 1
    fi
    echo "upstream-oracle: bench OK ($got, matches commit Bench:)" >&2
fi

echo "$BIN"
