#!/usr/bin/env bash
# Memory-error / leak gate (the ASan+LSan
# half). Runs the engine under Valgrind memcheck across thread counts and asserts
# no invalid read/write, no invalid/double free, and no DEFINITE leak.
#
# Why this and not -fsanitize=address: the runtime is a Zig+C++ binary; Valgrind
# instruments both without a sanitizer rebuild, and works on the exact artifact
# the parity gate ships. It directly targets the failure class the stage-4 cut
# and the native Worker/large-page lifecycle can introduce -- a missed free on
# teardown, a use-after-free in the idle-loop handshake, an out-of-bounds in the
# native ThreadPool construction. It is also the tool that would have caught the
# documented worker-uninitialized-memory landmine.
#
# Uninitialized-value checking is DISABLED (--undef-value-errors=no): the NNUE
# eval is heavy SSE/AVX and reads whole vector lanes incl. padding, which memcheck
# reports as false "uninitialised value" use. Leak / invalid-access / bad-free
# detection is unaffected and reliable. (The race half -- TSan/helgrind -- is
# deferred to stage 4: it is meaningful only for the native futex runtime, and the
# current C++ std::thread runtime has benign TT data races by design that a race
# gate would flag.)
#
# Usage: valgrind.sh <stockfish-binary>   (run with CWD = src/, so the net loads)
set -u

BIN="${1:?usage: valgrind.sh <stockfish-binary>}"
DEPTH="${VG_DEPTH:-9}"            # search depth per session (kept short; memcheck is ~20-50x)
WATCHDOG="${VG_WATCHDOG:-600}"    # seconds per valgrind session
THREADS=(1 2)

command -v valgrind >/dev/null 2>&1 || { echo "valgrind: SKIP -- valgrind not installed" >&2; exit 0; }

fail() { echo "valgrind: FAIL -- $*" >&2; exit 1; }

for tc in "${THREADS[@]}"; do
    echo "valgrind: memcheck session Threads=${tc} (go depth ${DEPTH})"
    log="$(mktemp)"
    printf 'uci\nsetoption name Threads value %d\nucinewgame\nposition startpos\ngo depth %d\nposition startpos moves e2e4 e7e5 g1f3\ngo depth %d\nquit\n' \
        "${tc}" "${DEPTH}" "${DEPTH}" \
        | timeout "${WATCHDOG}" valgrind \
            --tool=memcheck \
            --leak-check=full \
            --errors-for-leak-kinds=definite \
            --undef-value-errors=no \
            --error-exitcode=99 \
            "${BIN}" >/dev/null 2>"${log}"
    rc=$?
    if (( rc == 124 )); then rm -f "${log}"; fail "Threads=${tc} timed out under valgrind (${WATCHDOG}s)"; fi
    if (( rc == 99 )); then
        grep -iE "Invalid (read|write|free)|definitely lost|ERROR SUMMARY" "${log}" | head -12 >&2
        rm -f "${log}"
        fail "Threads=${tc} memcheck reported a memory error / definite leak"
    fi
    if (( rc != 0 )); then
        tail -8 "${log}" >&2
        rm -f "${log}"
        fail "Threads=${tc} exited ${rc} under valgrind"
    fi
    # Defensive: assert the summary line is actually clean even if exit slipped.
    if ! grep -q "definitely lost: 0 bytes in 0 blocks" "${log}"; then
        grep -i "definitely lost" "${log}" | head -3 >&2
        rm -f "${log}"
        fail "Threads=${tc} has a definite leak"
    fi
    rm -f "${log}"
done

echo "valgrind: OK (memcheck clean across Threads {${THREADS[*]}}: no leak / bad access)"
