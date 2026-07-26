#!/usr/bin/env bash
# upstream-transcript.
#
# Diff the WHOLE UCI transcript of the Zig build against the PRISTINE upstream oracle at
# the pinned target sha, over a matrix of command scripts. The bench signature
# (upstream_parity.sh) proves the two search the same tree; it says nothing about what the
# two PRINT. Every divergence found on the option/info surface so far -- the NumaPolicy
# parser, "Available processors" reading the affinity mask instead of the config -- was
# invisible to every gate in the tree and was found by hand, twice, after being missed by
# hand-written greps that only looked at the lines someone already suspected. Diff the
# whole transcript instead, so the next one is found by a gate.
#
# LOCAL-ONLY, like the other oracle glue: it needs the upstream worktree build, which CI
# does not have. Run it when touching the UCI, option, NUMA or info surface.
#
# Usage:  upstream_transcript.sh [<our-bin>] [<sha>]
set -uo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
OUR_BIN="${1:-$REPO/zig-out/bin/stockfish}"
SHA="${2:-$(cat "$REPO/tools/upstream/UPSTREAM_TARGET")}"
ORACLE_DIR="${ZFISH_ORACLE_DIR:-/home/usr00/_git/.zfish-upstream-oracle}"

ORACLE_BIN="$("$REPO/tools/upstream_oracle.sh" "$SHA")" || {
    echo "upstream-transcript: oracle build failed" >&2; exit 2; }

# Each engine runs from its own directory so each finds its own net copy; the two nets are
# byte-identical at the pin, so search output is comparable and is compared.
OUR_DIR="$REPO/resources"
THEIR_DIR="$ORACLE_DIR/src"

# Strip only what CANNOT match between two builds of different compilers: the version
# banner, and the wall-clock-derived fields. Everything else is compared byte for byte.
normalise() {
    sed -E -e '/^Stockfish dev-/d' \
           -e 's/^id name Stockfish dev-.*/id name Stockfish dev-V/' \
           -e '/^info string Available threads/d' \
           -e 's/ time [0-9]+/ time T/g' \
           -e 's/ nps [0-9]+/ nps N/g' \
           -e 's/ hashfull [0-9]+/ hashfull H/g' \
           -e 's/^(Total time \(ms\) *: ).*/\1T/' \
           -e 's/^(Nodes\/second *: ).*/\1N/'
}

# Declare the divergences that are KNOWN and traced to an unimplemented subsystem, so they
# are reported rather than silently tolerated -- and so a NEW one cannot hide behind them.
# Each entry is an extended regex matched against a diff line.
#
#   Network replica N: ... -- upstream's Engine::verify_network reports the per-NUMA-node
#   allocation status of the net (engine.cpp:266-299). It needs two subsystems zfish does
#   not have: NUMA replication of the network (zfish keeps one global feature-transformer
#   storage, so it has no per-node replicas to report) and upstream's 629-line src/shm.h
#   system-wide shared constant allocation (zfish loads the net into process-local memory,
#   so even a single replica could not honestly print "Shared memory."). Emitting the line
#   with a fabricated status would put a false statement in the transcript, which is worse
#   than the gap. Implementing it is a platform feature, not a reporting fix.
KNOWN_RE='^[<>] info string Network replica [0-9]+: '

pass=0; fail=0; known=0

run_case() {
    local label="$1" script="$2" prefix="${3:-}"
    local ours theirs delta unknown
    ours="$(cd "$OUR_DIR"   && printf '%s' "$script" | $prefix timeout 60 "$OUR_BIN"    2>&1 | normalise)"
    theirs="$(cd "$THEIR_DIR" && printf '%s' "$script" | $prefix timeout 60 "$ORACLE_BIN" 2>&1 | normalise)"

    if [ "$ours" = "$theirs" ]; then
        pass=$((pass + 1)); return
    fi

    delta="$(diff <(printf '%s\n' "$theirs") <(printf '%s\n' "$ours") | grep -E '^[<>]')"
    unknown="$(printf '%s\n' "$delta" | grep -Ev "$KNOWN_RE" | grep -E '^[<>]')"

    if [ -z "$unknown" ]; then
        known=$((known + 1))
        printf '  known %s (%d declared line(s))\n' "$label" "$(printf '%s\n' "$delta" | grep -c .)"
        return
    fi

    fail=$((fail + 1))
    printf '  DIFF  %s\n' "$label"
    printf '%s\n' "$unknown" | sed 's/^/          /' | head -20
}

# ---- the matrix ------------------------------------------------------------------
# Cover the surfaces a port drifts on: the handshake and the whole option listing, every
# NumaPolicy shape (valid, malformed, and the ones that exercise str_to_size_t's rule),
# the thread/hash options, position setup and its error paths, and the report commands.
#
# SEARCH OUTPUT IS COMPARED AT `Threads 1` ONLY. Lazy SMP is nondeterministic in BOTH
# engines, and oversubscribing it makes that loud: `taskset -c 1` with Threads 4 gives
# upstream 1, 1, then 2 info lines over three runs of the same command. Comparing that
# would make the gate flaky and, worse, would teach a reader to ignore its failures.
# Multi-thread cases therefore exercise the option/info surface with `isready` and leave
# the search to the single-threaded cases, which are deterministic on both sides.

printf 'handshake + option listing\n'
run_case 'uci' 'uci
quit
'
run_case 'isready before anything' 'isready
quit
'

printf 'NumaPolicy shapes\n'
for value in auto hardware none system \
             '0-3' '0-1:2-3' '0-3,8:4-7' '5,7,9' '7' \
             '0 1,2' '0,x,2' '0,0' '3-0' '1-2-3' 'x' ' x' '+2' '-1' '' \
             '0-99999999999' '0-1::2-3'; do
    run_case "NumaPolicy='$value'" "setoption name NumaPolicy value $value
setoption name Threads value 4
isready
quit
"
done

printf 'NumaPolicy under a restricted affinity mask\n'
for mask in 0-3 4-7 0,2,4,6 1; do
    run_case "taskset $mask, default policy" 'setoption name Threads value 4
isready
quit
' "taskset -c $mask"
    run_case "taskset $mask, NumaPolicy 0-1" 'setoption name NumaPolicy value 0-1
setoption name Threads value 4
isready
quit
' "taskset -c $mask"
    run_case "taskset $mask, NumaPolicy 0-1, 1 thread + go" 'setoption name NumaPolicy value 0-1
setoption name Threads value 1
go depth 6
quit
' "taskset -c $mask"
done

printf 'threads / hash / clear\n'
run_case 'Threads=1 + go' 'setoption name Threads value 1
go depth 8
quit
'
# Keep the thread counts MODEST. A Worker is ~15.5 MB resident (measured: 208 MB at
# Threads 1, 317 MB at Threads 8), so `Threads 1024` -- the option's own maximum -- is
# ~16 GB per engine and ~32 GB for the pair this harness runs. That is enough to take down
# a WSL2 VM, so the upper end of the range is deliberately NOT exercised here; the option's
# min/max is covered by the `uci` listing diff, which compares the declared bounds.
for threads in 2 8 16; do
    run_case "Threads=$threads (option surface)" "setoption name Threads value $threads
isready
quit
"
done
run_case 'Hash resize + Clear Hash' 'setoption name Hash value 32
setoption name Clear Hash value
ucinewgame
isready
quit
'
run_case 'Hash out of range' 'setoption name Hash value 999999999
isready
quit
'
run_case 'unknown option' 'setoption name NotAnOption value 3
isready
quit
'

printf 'position setup and its error paths\n'
run_case 'startpos + moves + go' 'setoption name Threads value 1
position startpos moves e2e4 e7e5 g1f3
go depth 8
quit
'
run_case 'fen + go' 'setoption name Threads value 1
position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1
go depth 7
quit
'
run_case 'chess960' 'setoption name Threads value 1
setoption name UCI_Chess960 value true
position fen bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9
go depth 7
quit
'
run_case 'MultiPV' 'setoption name Threads value 1
setoption name MultiPV value 3
position startpos
go depth 7
quit
'

printf 'report commands\n'
run_case 'd (board)' 'position startpos moves d2d4
d
quit
'
run_case 'eval trace' 'position startpos
eval
quit
'
run_case 'go perft' 'position startpos
go perft 4
quit
'
run_case 'flip' 'position startpos moves e2e4
flip
d
quit
'

echo
printf 'upstream-transcript: %d ok, %d known-divergent, %d FAILED (oracle %s)\n' \
    "$pass" "$known" "$fail" "${SHA:0:8}"
[ "$fail" -eq 0 ] || exit 1
