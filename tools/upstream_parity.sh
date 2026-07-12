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

sig() { ( cd "$2" && "$1" bench ) 2>&1 | sed -n 's/^Nodes searched  *: *\([0-9][0-9]*\).*/\1/p' | head -1; }

# Build/locate the pristine oracle at SHA.
ORACLE_BIN="$("$REPO/tools/upstream_oracle.sh" "$SHA")" || { echo "upstream-parity: oracle build failed" >&2; exit 2; }

ours="$(sig "$OUR_BIN" "$REPO/net")"
theirs="$(sig "$ORACLE_BIN" "$ORACLE_DIR/src")"

[ -z "$ours" ]   && { echo "upstream-parity: our binary produced no signature ($OUR_BIN)" >&2; exit 2; }
[ -z "$theirs" ] && { echo "upstream-parity: oracle produced no signature" >&2; exit 2; }

short="$(git -C "$REPO" rev-parse --short "$SHA")"
if [ "$ours" = "$theirs" ]; then
    echo "upstream-parity: OK (native == upstream@$short: $ours)"
    exit 0
fi
echo "upstream-parity: BEHIND (native=$ours  upstream@$short=$theirs)  -- resync in progress" >&2
exit 1
