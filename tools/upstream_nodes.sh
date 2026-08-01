#!/usr/bin/env bash
# Node-count divergence localizer.
#
# When several search commits land together and the final bench is close-but-off, you need to find WHICH
# commit/condition diverges. This builds the pristine oracle at <sha> (which carries its own net) and
# compares `go depth <depth>` node counts for our native build vs that oracle, on one or more FENs.
# Bisect <sha> over the suspect commits: the first sha whose node count diverges localizes the bug.
#
# An apples-to-apples node compare requires our build to load the SAME net as oracle@<sha>, and this
# REFUSES TO RUN when it does not. A comment used to say so, which is worth nothing here: a stale
# ORACLE_DIR left from an earlier session, or a resources/ missing its net, makes every position diverge
# from the first ply -- indistinguishable from the search bug this script exists to localize, and it is
# reached for at exactly the moment you are already expecting a divergence. Both engines print
# `NNUE evaluation using <file>.nnue` before the first search, so the check costs nothing.
#
# If <sha> genuinely uses a different net from our current default, point our EvalFile at it first (or
# bisect over a sha sharing our net).
#
# Usage:
#   upstream_nodes.sh <sha> [depth] [fen...]
#     sha    upstream commit to build the oracle at (default: UPSTREAM_TARGET)
#     depth  go depth (default 14)
#     fen    one or more FENs or the word "startpos" (default: a small mixed suite)
set -uo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
TOOLS="$REPO/tools"
ORACLE_DIR="${ZFISH_ORACLE_DIR:-/home/usr00/_git/.zfish-upstream-oracle}"
OUR_BIN="${ZFISH_OUR_BIN:-$REPO/zig-out/bin/stockfish}"

SHA="${1:-$(cat "$TOOLS/upstream/UPSTREAM_TARGET")}"; shift || true
DEPTH="${1:-14}"; [ $# -gt 0 ] && shift || true
if [ $# -gt 0 ]; then FENS=("$@"); else
    FENS=(
        "startpos"
        "r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4"
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"
    )
fi

ORACLE_BIN="$("$TOOLS/upstream_oracle.sh" "$SHA")" || { echo "nodes: oracle build failed" >&2; exit 2; }
[ -x "$OUR_BIN" ] || { echo "nodes: our binary not found at $OUR_BIN (build with: zig build -Darch=...)" >&2; exit 2; }

# Run ONE real search per position. Our binary needs a trailing pause before `quit` (else `go depth N`
# returns a depth-1 stub), and emits info to stderr -- so we hold stdin open with a sleep and capture 2>&1.
SLEEP="${ZFISH_GO_SLEEP:-$((DEPTH / 2 + 2))}"
run_go() { # $1=cwd $2=bin $3=fen  -> full (slept) go output
    local pos; if [ "$3" = "startpos" ]; then pos="position startpos"; else pos="position fen $3"; fi
    ( cd "$1" && { printf 'uci\nisready\n%s\ngo depth %s\n' "$pos" "$DEPTH"; sleep "$SLEEP"; printf 'quit\n'; } | "$2" 2>&1 )
}
nodes_of() { printf '%s\n' "$1" | grep -E "^info depth $DEPTH " | grep -oE 'nodes [0-9]+' | tail -1 | grep -oE '[0-9]+'; }
bm_of() { printf '%s\n' "$1" | sed -n 's/^bestmove \([a-h0-9nbrq]*\).*/\1/p' | tail -1; }
net_of() { printf '%s\n' "$1" | sed -n 's/.*NNUE evaluation using \([^ ]*\.nnue\).*/\1/p' | tail -1; }

# Refuse the comparison unless both engines loaded the SAME net. The net is reported LAZILY, on first
# use, so this has to come from a run that actually searched -- a bare `uci`/`isready` prints nothing.
short="$(git -C "$REPO" rev-parse --short "$SHA")"
probe_ours="$(run_go "$REPO/resources" "$OUR_BIN" "startpos")"
probe_oracle="$(run_go "$ORACLE_DIR/src" "$ORACLE_BIN" "startpos")"
net_ours="$(net_of "$probe_ours")"
net_oracle="$(net_of "$probe_oracle")"
if [ -z "$net_ours" ] || [ -z "$net_oracle" ] || [ "$net_ours" != "$net_oracle" ]; then
    echo "nodes: REFUSING to compare -- the two engines did not load the same net." >&2
    echo "nodes:   ours          : ${net_ours:-<none loaded>}   (cwd $REPO/resources)" >&2
    echo "nodes:   oracle@$short : ${net_oracle:-<none loaded>}   (cwd $ORACLE_DIR/src)" >&2
    echo "nodes: Node counts across different nets are meaningless -- every position would diverge" >&2
    echo "nodes: from the first ply, which looks exactly like the bug you are hunting. Fix the net" >&2
    echo "nodes: (zig build net, or point EvalFile at the one oracle@$short uses) and re-run." >&2
    exit 2
fi
printf "nodes: both engines on %s\n" "$net_ours"

printf "go depth %s (sleep %ss) : ours vs oracle@%s\n" "$DEPTH" "$SLEEP" "$short"
printf "%14s %14s  %-6s %-7s %s\n" "OURS(nodes)" "ORACLE(nodes)" "bm-ok" "n-ok" "FEN"
bad=0
for f in "${FENS[@]}"; do
    oo="$(run_go "$REPO/resources" "$OUR_BIN" "$f")"
    ro="$(run_go "$ORACLE_DIR/src" "$ORACLE_BIN" "$f")"
    on="$(nodes_of "$oo")"; rn="$(nodes_of "$ro")"
    ob="$(bm_of "$oo")"; rb="$(bm_of "$ro")"
    bm="ok"; [ "$ob" != "$rb" ] && bm="DIFF"
    nk="ok"; [ "$on" != "$rn" ] && nk="DIFF"; { [ -z "$on" ] || [ -z "$rn" ]; } && nk="?"
    { [ "$bm" = DIFF ] || [ "$nk" = DIFF ]; } && bad=$((bad+1))
    printf "%14s %14s  %-6s %-7s %s\n" "${on:-?}" "${rn:-?}" "$bm" "$nk" "${f:0:40}"
done
echo ""
[ "$bad" -eq 0 ] && echo "nodes: MATCH (our search == oracle@$short at depth $DEPTH on all FENs)" \
                 || { echo "nodes: $bad/${#FENS[@]} positions DIVERGE -> bisect <sha> earlier to localize"; exit 1; }
