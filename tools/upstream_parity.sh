#!/usr/bin/env bash
# upstream-parity.
#
# Assert the native Zig default build's bench == the PRISTINE upstream oracle's bench at the current
# target sha. This is the whole-engine convergence gate for the resync. It is RED until the port catches
# up to upstream -- that red is the worklist, not a failure.
#
# Our binary and the oracle binary load DIFFERENT nets (our EvalFileDefaultName vs upstream's), so each is
# run from its own net directory.
#
# Usage:  upstream_parity.sh [<our-default-bin>] [<sha>]
#   our-default-bin defaults to <repo>/zig-out/bin/stockfish (build it with `zig build -Darch=...`)
#   sha             defaults to tools/upstream/UPSTREAM_TARGET
set -uo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
OUR_BIN="${1:-$REPO/zig-out/bin/stockfish}"
SHA="${2:-$(cat "$REPO/tools/upstream/UPSTREAM_TARGET")}"
ORACLE_DIR="${ZFISH_ORACLE_DIR:-/home/usr00/_git/.zfish-upstream-oracle}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Run one binary's bench from its own net directory, echo its node count, and leave the
# raw output in $WORK/<tag>.log plus the exit status in $WORK/<tag>.rc. Assigning globals
# would not survive the caller's command substitution, so the evidence travels on disk.
sig() {
    local tag="$1" bin="$2" dir="$3"
    ( cd "$dir" && "$bin" bench ) >"$WORK/$tag.log" 2>&1
    echo $? >"$WORK/$tag.rc"
    sed -n 's/^Nodes searched  *: *\([0-9][0-9]*\).*/\1/p' "$WORK/$tag.log" | head -1
}

# Explain an empty signature instead of merely naming it. An empty node count means "no
# node-count line", which a crash, a missing net and a usage error all produce alike --
# and a silent one cost a whole debugging detour once already.
die_no_sig() {
    local tag="$1" who="$2" what="$3"
    local rc; rc="$(cat "$WORK/$tag.rc" 2>/dev/null || echo 0)"
    echo "upstream-parity: $who produced no signature ($what)" >&2
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -gt 128 ]; then
            echo "upstream-parity:   bench died on signal $((rc - 128)) (exit $rc)" >&2
        else
            echo "upstream-parity:   bench exited $rc" >&2
        fi
        if [ "$tag" = oracle ]; then
            echo "upstream-parity:   a crashing oracle is usually a stale incremental build --" >&2
            echo "upstream-parity:   objects from the previous sha relinked against reshaped headers." >&2
            echo "upstream-parity:   Force a clean one:" >&2
            echo "upstream-parity:     rm -f '$ORACLE_DIR/src/.zfish_oracle_stamp' && tools/upstream_oracle.sh" >&2
        fi
    fi
    echo "upstream-parity:   last lines of its output:" >&2
    tail -5 "$WORK/$tag.log" 2>/dev/null | sed 's/^/upstream-parity:   | /' >&2
    exit 2
}

# Build/locate the pristine oracle at SHA.
ORACLE_BIN="$("$REPO/tools/upstream_oracle.sh" "$SHA")" || { echo "upstream-parity: oracle build failed" >&2; exit 2; }

ours="$(sig ours "$OUR_BIN" "$REPO/resources")"
theirs="$(sig oracle "$ORACLE_BIN" "$ORACLE_DIR/src")"

[ -z "$ours" ]   && die_no_sig ours   "our binary" "$OUR_BIN"
[ -z "$theirs" ] && die_no_sig oracle "oracle"     "$ORACLE_BIN"

short="$(git -C "$REPO" rev-parse --short "$SHA")"
if [ "$ours" = "$theirs" ]; then
    echo "upstream-parity: OK (native == upstream@$short: $ours)"
    exit 0
fi
echo "upstream-parity: BEHIND (native=$ours  upstream@$short=$theirs)  -- resync in progress" >&2
exit 1
