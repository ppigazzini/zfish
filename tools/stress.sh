#!/usr/bin/env bash
# Harness H2 (REPORT-09 big-bang plan): thread-runtime stress / liveness.
#
# The stage-4 cut replaces the C++ std::thread / idle_loop / condition-variable
# runtime with a native futex runtime. The existing parity gate is single-shot
# and single-threaded, so it cannot see a deadlock, a lost wakeup, or a teardown
# crash under load -- exactly the failure modes the native runtime can introduce.
#
# This harness hammers the lifecycle the cut touches: many (ucinewgame ->
# setoption Threads -> go/stop) cycles in one process across a range of thread
# counts, plus a process-churn phase (construct + destroy the whole engine graph
# repeatedly). Every search must return a bestmove and every invocation must exit
# cleanly within a wall-clock watchdog; a hang trips `timeout` and fails the gate.
#
# It is a LIVENESS gate, not a determinism gate: multi-threaded search is
# non-deterministic, so it asserts "completed + legal-shaped bestmove + no hang /
# crash", never an exact node count. Captured now against the C++ runtime, it
# becomes the regression net the native runtime must still pass.
#
# Usage: stress.sh <stockfish-binary>   (run with CWD = src/, so the net loads)
set -u

BIN="${1:?usage: stress.sh <stockfish-binary>}"
WATCHDOG="${STRESS_WATCHDOG:-40}"   # seconds per process invocation
CYCLES="${STRESS_CYCLES:-24}"       # go/stop cycles in the in-process storm
CHURN="${STRESS_CHURN:-12}"         # construct/destroy iterations
THREADS=(1 2 4 8)

fail() { echo "stress: FAIL -- $*" >&2; exit 1; }

# ---- Phase A: in-process go/stop storm across thread counts ------------------
# Build one long command stream: per cycle, pick a thread count, ucinewgame, then
# either a bounded `go depth` (auto-terminates) or `go infinite` + a `stop` after
# a short settle (exercises the stop handshake). Count bestmoves == cycles.
build_stream() {
    echo "uci"
    echo "setoption name Hash value 16"
    local i tc
    for ((i = 0; i < CYCLES; i++)); do
        tc=${THREADS[$((i % ${#THREADS[@]}))]}
        echo "setoption name Threads value ${tc}"
        echo "ucinewgame"
        echo "isready"
        if (( i % 3 == 0 )); then
            # stop-handshake path: start an unbounded search, let it spin up, stop.
            echo "position startpos"
            echo "go infinite"
            echo "__SLEEP__"        # placeholder, expanded by the feeder
            echo "stop"
        else
            # bounded path: a short multi-threaded search that self-terminates.
            echo "position startpos moves e2e4 e7e5"
            echo "go depth 10"
        fi
    done
    echo "quit"
}

# Feed the stream with real sleeps where the placeholder sits, so `stop` lands
# while the infinite search is actually running.
feed_stream() {
    while IFS= read -r line; do
        if [[ "$line" == "__SLEEP__" ]]; then
            sleep 0.15
        else
            printf '%s\n' "$line"
        fi
    done
}

echo "stress: phase A -- ${CYCLES} go/stop cycles across threads {${THREADS[*]}}"
out_a="$(build_stream | feed_stream | timeout "${WATCHDOG}" "${BIN}" 2>&1)"
rc=$?
if (( rc == 124 )); then fail "phase A hung (watchdog ${WATCHDOG}s) -- deadlock?"; fi
if (( rc != 0 )); then
    echo "$out_a" | tail -5 >&2
    fail "phase A exited ${rc} (crash/abort)"
fi
got=$(printf '%s\n' "$out_a" | grep -c '^bestmove ')
if (( got != CYCLES )); then
    fail "phase A produced ${got} bestmoves, expected ${CYCLES} (lost search?)"
fi
# Every bestmove must name a move or (none); an empty/garbled line is a failure.
if printf '%s\n' "$out_a" | grep '^bestmove ' | grep -qvE '^bestmove ([a-h][1-8][a-h][1-8][qrbn]?|\(none\))'; then
    fail "phase A emitted a malformed bestmove line"
fi

# ---- Phase B: process churn (construct + destroy the engine graph) -----------
echo "stress: phase B -- ${CHURN} construct/destroy iterations"
for ((j = 0; j < CHURN; j++)); do
    tc=${THREADS[$((j % ${#THREADS[@]}))]}
    out_b="$(printf 'uci\nsetoption name Threads value %d\nucinewgame\nposition startpos\ngo depth 8\nquit\n' "${tc}" \
        | timeout "${WATCHDOG}" "${BIN}" 2>&1)"
    rc=$?
    if (( rc == 124 )); then fail "phase B iter ${j} (Threads=${tc}) hung"; fi
    if (( rc != 0 )); then
        echo "$out_b" | tail -5 >&2
        fail "phase B iter ${j} (Threads=${tc}) exited ${rc}"
    fi
    if ! printf '%s\n' "$out_b" | grep -q '^bestmove '; then
        fail "phase B iter ${j} (Threads=${tc}) produced no bestmove"
    fi
done

echo "stress: OK (phase A ${CYCLES} cycles + phase B ${CHURN} churns, no hang/crash)"
