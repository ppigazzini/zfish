#!/usr/bin/env bash
# Harness H5 (REPORT-9 big-bang plan): leak gate for the std::vector lifecycle
# stage 5 ports -- Worker::set_limits (limits.searchmoves, a std::vector<string>)
# and set_root_moves (worker.rootMoves) -- plus Worker::clear churn.
#
# bench never sets searchmoves, so the searchmoves vector's allocate/free is
# UN-exercised by the existing gate; a native stage-5 vector-assign that frees it
# with the wrong allocator (the Worker is natively destructed) would leak silently.
# H5 drives `go searchmoves <moves>` + ucinewgame repeatedly under Valgrind
# memcheck and asserts no definite leak / bad free / invalid access. Captured
# against the current C++ runtime as the baseline the native port must match.
#
# IMPORTANT teardown quirk (finding, ITERATION-152): under memcheck this engine's
# PROCESS EXIT hangs in the C++ thread-join after valgrind has already printed its
# leak/error summary (valgrind serializes threads and the idle_loop join stalls;
# a Threads resize hangs outright). The leak VERDICT is therefore reliably in the
# log even though the process never returns -- so H5 reads the verdict from the
# log and treats a post-summary watchdog kill as success. (The thread-join-under-
# serialization pathology is stage-4 intel for the native futex runtime.)
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
