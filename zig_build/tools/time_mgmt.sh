#!/usr/bin/env bash
# Wall-clock time-management sanity gate (REPORT-15 §9).
#
# WHY THIS EXISTS: the rest of the parity battery is entirely depth/node-limited
# (bench, signature, search-parity, search-modes, mt_sanity all drive `go depth`
# or a node cap). Wall-clock time management -- `go movetime`, `go wtime/btime`,
# the TimeManagement.startTime epoch, the elapsed-vs-budget stop test -- is driven
# by NONE of them. That blind spot let a real bug ship: the native `go` owner
# never set `limits.startTime`, so `elapsed = now() - startTime` read as now()-0
# (~machine uptime); `go movetime T` then saw elapsed >> T and returned instantly,
# and every info line printed `time <uptime>`. No gate saw it (fixed in fbcefd0d6).
#
# Time management is non-deterministic, so there is no bit-exact golden. Instead
# this asserts INVARIANTS that any correct clock satisfies and that bug violated:
#   1. BAND   -- `go movetime T` reports an elapsed `time N` within a generous band
#                of T, and returns a legal bestmove. The startTime=0 bug put N at
#                ~uptime (millions); an over-eager stop puts N near 0.
#   2. SCALE  -- reported time grows with the budget (N(900) > N(300)); a frozen or
#                constant clock fails this even if it happens to land in the band.
#   3. ALLOC  -- `go wtime/btime` allocates a sane sub-budget (0 < time <= budget)
#                and returns a legal move -- exercises the time-allocation path,
#                which movetime bypasses.
#
# On why there is no separate REAL wall-clock assertion: N is `now() - startTime`
# and the stop test is `now() - startTime >= budget` -- the same read -- so a
# correct, scaling N implies the search really blocked for ~N ms, PROVIDED now()
# returns real time. It does: now() (zfish_now = CLOCK_MONOTONIC ms) is the same
# clock the bench "Total time (ms)" summary reports, which is separately validated
# as sane. Measuring the search's real wall-clock from the shell is unreliable
# anyway (stdin must be held open past the budget, and engine stdout buffering
# skews when the bestmove line surfaces), so such a check would be hollow.
#
# Usage: time_mgmt.sh <stockfish-bin>   (run with cwd = src/ so the NNUE net loads)
set -u

BIN="${1:?usage: time_mgmt.sh <stockfish-bin>}"
WATCHDOG="${TM_WATCHDOG:-40}"

fail() { echo "time-mgmt: FAIL -- $*" >&2; exit 1; }

# Drive one timed search and capture output through the `bestmove` line. stdin is
# held open (sleep) past the budget so the engine self-terminates at its time limit
# rather than on an early stdin-EOF (this UCI loop treats EOF-after-go as quit).
# Read the engine directly -- no `tr`/`grep` pipe stage, which would block-buffer
# and hide bestmove until EOF. Sets OUT.
OUT=""
run_timed() {  # $1 = go arguments   $2 = stdin-hold seconds
    local hold_s="$2" tmp line
    tmp="$(mktemp)"
    while IFS= read -r line; do
        line="${line%$'\r'}"
        printf '%s\n' "$line" >>"$tmp"
        case "$line" in bestmove*) break ;; esac
    done < <( { printf 'uci\nisready\nposition startpos\ngo %s\n' "$1"
                sleep "$hold_s"; } \
              | timeout "$WATCHDOG" "$BIN" 2>/dev/null )
    OUT="$(cat "$tmp")"; rm -f "$tmp"
}

reported_time() { printf '%s\n' "$OUT" | grep -oE 'time [0-9]+' | tail -1 | grep -oE '[0-9]+'; }
has_legal_bestmove() { printf '%s\n' "$OUT" | grep -qE '^bestmove [a-h][1-8][a-h][1-8][qrbn]?( |$)'; }

# 1 + 2: movetime band + scale.
declare -A REP
for T in 300 900; do
    run_timed "movetime $T" "$(awk "BEGIN{print $T/1000 + 4}")"
    has_legal_bestmove || fail "movetime $T: no legal bestmove (search did not run to the time limit)"
    n="$(reported_time)"
    [ -n "$n" ] || fail "movetime $T: engine reported no 'time' field"
    lo=$(( T / 3 )); hi=$(( 3 * T + 1500 ))
    { [ "$n" -ge "$lo" ] && [ "$n" -le "$hi" ]; } \
        || fail "movetime $T: reported time ${n}ms outside [$lo,$hi] -- startTime/clock regression (bug read ~uptime)"
    REP[$T]="$n"
    echo "time-mgmt: movetime ${T} -> reported ${n}ms, bestmove ok"
done
[ $(( REP[900] - REP[300] )) -ge 200 ] \
    || fail "reported time does not scale with budget (300->${REP[300]}ms, 900->${REP[900]}ms) -- constant/frozen clock"

# 3: wtime/btime allocates a sane sub-budget and returns a legal move.
run_timed "wtime 3000 btime 3000" 5
has_legal_bestmove || fail "wtime/btime: no legal bestmove"
w="$(reported_time)"
[ -n "$w" ] || fail "wtime/btime: engine reported no 'time' field"
{ [ "$w" -ge 1 ] && [ "$w" -le 3000 ]; } \
    || fail "wtime/btime: allocated ${w}ms outside (0,3000] -- time allocation regression"
echo "time-mgmt: wtime/btime 3000 -> allocated ${w}ms, bestmove ok"

echo "time-mgmt: OK (movetime band+scale, wtime allocation)"
