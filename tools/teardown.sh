#!/usr/bin/env bash
# Valgrind leak gate for the searchmoves / rootMoves list lifecycle plus Worker clear
# churn -- paths bench never exercises. bench never sets searchmoves, so the searchmoves
# list's allocate/free is otherwise un-gated; a Worker teardown that frees it with the
# wrong allocator would leak silently. Drives `go searchmoves <moves>` + ucinewgame
# repeatedly under Valgrind memcheck and asserts no definite leak / bad free / invalid access.
#
# IMPORTANT teardown quirk: under memcheck this engine's process exit hangs in the
# thread-join after valgrind has already printed its leak/error summary (valgrind serializes
# threads and the idle-loop join stalls; a Threads resize hangs outright). The leak VERDICT is
# therefore reliably in the log even though the process never returns -- so this gate reads the
# verdict from the log and treats a post-summary watchdog kill as success.
#
# Usage: teardown.sh <stockfish-binary>   (CWD = src/, so the net loads)
set -u

BIN="${1:?usage: teardown.sh <stockfish-binary>}"
WATCHDOG="${TD_WATCHDOG:-240}"
DEPTH="${TD_DEPTH:-4}"

command -v valgrind >/dev/null 2>&1 || { echo "teardown: SKIP -- valgrind not installed" >&2; exit 0; }
fail() { echo "teardown: FAIL -- $*" >&2; exit 1; }

stream() {
    printf 'uci\nsetoption name Hash value 16\nsetoption name Threads value 1\n'
    for _ in 1 2 3 4; do
        printf 'ucinewgame\nposition startpos\ngo searchmoves e2e4 d2d4 c2c4 g1f3 depth %d\n' "$DEPTH"
        printf 'ucinewgame\nposition startpos moves e2e4 e7e5\ngo searchmoves d2d4 g1f3 depth %d\n' "$DEPTH"
        printf 'ucinewgame\nposition startpos moves d2d4 d7d5 c2c4\ngo depth %d\n' "$DEPTH"
    done
    printf 'quit\n'
}

echo "teardown: memcheck searchmoves+clear churn (Threads=1, depth ${DEPTH})"
log="$(mktemp)"
stream | timeout "${WATCHDOG}" valgrind \
    --tool=memcheck --leak-check=full --errors-for-leak-kinds=definite \
    --undef-value-errors=no \
    "${BIN}" >/dev/null 2>"${log}"
rc=$?

# Verdict comes from valgrind's own summary, which is emitted before the post-exit
# thread-join hang. Require BOTH the clean leak line and the clean error summary.
leak_line="$(grep -i 'definitely lost' "$log" | tail -1)"
err_line="$(grep -i 'ERROR SUMMARY' "$log" | tail -1)"

if [ -z "$leak_line" ] || [ -z "$err_line" ]; then
    # No summary -> valgrind never reached program exit (hung mid-run, or crashed).
    tail -8 "$log" >&2; rm -f "$log"
    fail "no valgrind summary produced (rc=${rc}); memcheck did not complete"
fi
if grep -qiE "Invalid (read|write|free)|Mismatched free" "$log"; then
    grep -iE "Invalid (read|write|free)|Mismatched free" "$log" | head -6 >&2
    rm -f "$log"; fail "memcheck reported an invalid access / bad free"
fi
if ! printf '%s' "$leak_line" | grep -q "0 bytes in 0 blocks"; then
    echo "$leak_line" >&2; rm -f "$log"; fail "definite leak in the searchmoves/rootMoves/clear lifecycle"
fi
if ! printf '%s' "$err_line" | grep -qE "0 errors from 0 contexts"; then
    echo "$err_line" >&2; rm -f "$log"; fail "memcheck reported errors"
fi
rm -f "$log"
# rc 124 here is the documented post-summary teardown hang, not a leak failure.
[ "$rc" = "124" ] && echo "teardown: (note: process hung in post-exit thread-join under memcheck -- expected)"
echo "teardown: OK (searchmoves + ucinewgame churn: no leak / bad access)"
