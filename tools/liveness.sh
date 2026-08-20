#!/usr/bin/env bash
# Does the engine still ANSWER? -- the defect class no other gate here can express.
#
# WHAT THIS PROVES. For each case below, an engine given a command mid-search, or a
# self-limiting search, produces a `bestmove` within a deadline this script owns.
# Nothing else: it does not read the move, the score, or the node count.
#
# WHAT IT CANNOT SEE. A WRONG answer. Every other gate in this tree compares against a
# known-good result and is blind to a hang; this one is blind to everything a hang is
# not. `driver-golden` diffs text and `search-modes` reads bestmoves -- to both of them
# a wedged engine is the HARNESS timing out, and a harness timeout reads as a rig fault
# rather than a detection unless something owns the clock and calls it a hang.
#
# WHY THIS IS A SEPARATE GATE AND NOT A DEADLINE IN THE SHARED DRIVER.
# tools/parity/session.zig states, deliberately, that `fillUntil` carries NO deadline:
# a slow runner crossing one would turn a correct engine red, and a flaky gate is not
# evidence. That argument is right and is left standing. It holds because every golden
# gate measures a search whose real duration is the thing under test. Here the duration
# is not under test -- every case below answers in MILLISECONDS when it answers at all,
# so a deadline of seconds is four orders of magnitude of headroom rather than a race.
# The deadline lives here, on the cases that need one, and nowhere else.
#
# THE CASES ARE THIS TREE'S OWN REGISTER, not an inherited list. Each was live here,
# each was fixed by the commit named beside it, and `--mutate` shows the case going red
# when that fix is taken away. A case nobody can make fail is a claim, not a check.
#
# Exit codes:  0 every case answered   1 a case hung   2 could not run
set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN=${1:-${BIN:-$ROOT/zig-out/bin/stockfish}}
DEADLINE=${DEADLINE:-10}

# Run from resources/: the net is a runtime input and the binary SIGSEGVs on a null net
# from any other cwd (AGENTS.md). Everything below therefore names paths relative to it.
cd "$ROOT/resources" 2>/dev/null || { echo "liveness: SKIPPED -- no resources/ dir" >&2; exit 2; }
[ -x "$BIN" ] || { echo "liveness: SKIPPED -- no engine at $BIN" >&2; exit 2; }
[ -f nn-1a298aa575a0.nnue ] || { echo "liveness: SKIPPED -- no net in resources/ (run 'zig build bench')" >&2; exit 2; }

PASSED=0
HUNG=0

# Drive one case and require a bestmove before the deadline.
#
# stdin is a FIFO held open read-write for the whole case. That is the load-bearing
# detail: this engine treats stdin EOF during `go` as a stop, so feeding a script down a
# pipe makes every case answer and the gate proves nothing. The fifo never reaches EOF,
# so the only thing that can produce a bestmove is the engine deciding to.
run_case() {
    local name=$1 script=$2
    local fifo out waited
    fifo=$(mktemp -u "${TMPDIR:-/tmp}/zfish-liveness-XXXXXX")
    out=$(mktemp "${TMPDIR:-/tmp}/zfish-liveness-out-XXXXXX")
    mkfifo "$fifo" || { echo "liveness: SKIPPED -- cannot mkfifo" >&2; exit 2; }

    exec 9<>"$fifo"
    "$BIN" <"$fifo" >"$out" 2>/dev/null &
    local pid=$!
    printf '%b' "$script" >&9

    waited=0
    while [ "$waited" -lt "$((DEADLINE * 10))" ]; do
        grep -q '^bestmove' "$out" 2>/dev/null && break
        kill -0 "$pid" 2>/dev/null || break   # exited: one more look below settles it
        sleep 0.1
        waited=$((waited + 1))
    done

    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    exec 9>&-
    rm -f "$fifo"

    if grep -q '^bestmove' "$out" 2>/dev/null; then
        echo "  ok     $name"
        PASSED=$((PASSED + 1))
    else
        echo "  HANG   $name -- no bestmove within ${DEADLINE}s"
        sed 's/^/           /' "$out" | tail -4
        HUNG=$((HUNG + 1))
    fi
    rm -f "$out"
}

# Require a command that runs its OWN searches to terminate. `bench` holds the UCI thread
# inside the wait, so a search with no stop condition is unreachable by `stop` or `quit`:
# nothing can rescue it and no bestmove is ever printed.
run_selfdriving() {
    local name=$1 script=$2 out rc
    out=$(mktemp "${TMPDIR:-/tmp}/zfish-liveness-out-XXXXXX")
    printf '%b' "$script" | timeout "$DEADLINE" "$BIN" >"$out" 2>&1
    rc=$?
    if [ "$rc" -eq 124 ]; then
        echo "  HANG   $name -- did not finish within ${DEADLINE}s"
        sed 's/^/           /' "$out" | tail -4
        HUNG=$((HUNG + 1))
    else
        echo "  ok     $name"
        PASSED=$((PASSED + 1))
    fi
    rm -f "$out"
}

echo "liveness: $BIN, deadline ${DEADLINE}s"
echo
echo "== a command that mutates state a worker holds, sent mid-search =="
run_case "setoption during go infinite   (5f524ff8)" \
    'setoption name Threads value 2\nposition startpos\ngo infinite\nsetoption name Hash value 32\n'
run_case "setoption during go ponder     (5f524ff8)" \
    'position startpos\ngo ponder\nsetoption name Hash value 32\n'

echo
echo "== a search whose own limit is the defect =="
run_case "go movetime 0                  (160a4a5c)" \
    'position startpos\ngo movetime 0\n'
# NOT a case here: `go ... movestogo -2147483648`. It was tried, and it survives BOTH
# mutations below -- that defect makes the engine answer too FAST, from a depth-4 search
# on a full clock, and this gate cannot see a wrong answer. It is carried by a unit test
# in uci_parse.zig instead. A case nobody can make fail belongs in neither place.

echo
echo "== a self-driving command with no reader left to rescue it =="
run_selfdriving "bench 16 1 0 default movetime  (160a4a5c)" \
    'bench 16 1 0 default movetime\nquit\n'

echo
if [ "$HUNG" -eq 0 ]; then
    echo "liveness: OK ($PASSED case(s) answered, 0 hung)"
else
    echo "liveness: FINDINGS ($PASSED answered, $HUNG hung)"
fi
exit $((HUNG > 0 ? 1 : 0))
