#!/usr/bin/env bash
# Harness H1 (REPORT-09 big-bang plan): multi-thread search SANITY.
#
# Multi-threaded search is non-deterministic (Lazy SMP: helper threads race on the
# shared TT), so there is NO bit-exact signature to gate -- unlike the
# single-thread search-parity golden. What CAN be anchored is gross sanity: at a
# fixed depth on calm positions, the search must still complete, emit a
# well-formed bestmove, and return a score in the same neighbourhood as the
# (deterministic) single-thread reference. A native stage-4 runtime that runs but
# corrupts result aggregation -- wrong thread voting, garbled scores, a dropped
# main-thread PV -- fails that band even though no bit-exact gate could see it.
#
# The GOLDEN is the single-thread (deterministic) score+bestmove per position.
# CHECK runs Threads {2,4} and asserts, per position: a well-formed bestmove, a
# numeric score of the same kind (cp/mate) and sign, and |mt - st| <= BAND for cp.
# The band is deliberately generous (never false-fail on legitimate SMP variance);
# it catches garbage (wrong sign, hundreds of cp off, non-numeric), not nuance.
#
# Captured now against the live C++ runtime; the native runtime must still pass.
#
# Usage: mt_sanity.sh <stockfish-bin> <golden-file> [check|update]
# Run with cwd = src/ so the external NNUE net resolves.
set -u

BIN="${1:?usage: mt_sanity.sh <bin> <golden> [check|update]}"
GOLDEN="${2:?golden path required}"
MODE="${3:-check}"
DEPTH="${MT_DEPTH:-12}"
BAND="${MT_BAND:-150}"          # cp tolerance vs single-thread reference

# Calm positions -- scores are stable across thread counts (no sharp tactics that
# a helper thread would swing past the band).
declare -A POS=(
    [startpos]='position startpos'
    [open]='position startpos moves e2e4 e7e5 g1f3 b8c6 f1b5 a7a6'
    [endgame]='position fen 8/5k2/4p3/4P3/5K2/8/8/8 w - - 0 1'
    [queens]='position startpos moves d2d4 d7d5 c2c4 e7e6 b1c3 g8f6'
)
ORDER=(startpos open endgame queens)

# Extract the final "score cp X" / "score mate Y" from a search (multipv 1 / no
# multipv -> the last score line before bestmove), and the bestmove move text.
# A trailing sleep before quit is REQUIRED: this UCI loop treats stdin EOF right
# after `go` as quit and truncates the search at depth 1 (returning the first
# legal move). The sleep lets the fixed-depth search complete and emit its real
# bestmove/score before EOF.
run_score() {
    local cmds="$1" out
    out="$({ printf '%b\n' "$cmds"; sleep "${MT_SLEEP:-2}"; printf 'quit\n'; } \
        | timeout "${MT_WATCHDOG:-30}" "$BIN" 2>/dev/null | tr -d '\r')"
    local score bm
    score="$(printf '%s\n' "$out" | grep -oE 'score (cp|mate) -?[0-9]+' | tail -1)"
    bm="$(printf '%s\n' "$out" | grep -oE '^bestmove [a-h][1-8][a-h][1-8][qrbn]?' | tail -1)"
    printf '%s|%s' "${score:-NONE}" "${bm:-NONE}"
}

emit_golden() {
    local name r
    for name in "${ORDER[@]}"; do
        r="$(run_score "setoption name Threads value 1\n${POS[$name]}\ngo depth ${DEPTH}")"
        printf '%-10s %s\n' "$name" "$r"
    done
}

if [ "$MODE" = "update" ]; then
    emit_golden > "$GOLDEN"
    echo "mt-sanity: wrote golden ($(grep -c . "$GOLDEN") positions, depth ${DEPTH})"
    exit 0
fi

[ -f "$GOLDEN" ] || { echo "mt-sanity: golden missing: $GOLDEN (run update first)" >&2; exit 2; }

fail() { echo "mt-sanity: FAIL -- $*" >&2; exit 1; }

score_kind() { printf '%s\n' "$1" | awk '{print $2}'; }   # cp|mate
score_val()  { printf '%s\n' "$1" | awk '{print $3}'; }    # integer

for name in "${ORDER[@]}"; do
    gline="$(grep "^${name} " "$GOLDEN")"
    [ -n "$gline" ] || fail "golden has no entry for ${name} (regenerate)"
    g_pair="${gline#"${name}"}"; g_pair="$(printf '%s' "$g_pair" | xargs)"
    g_score="${g_pair%%|*}"
    g_kind="$(score_kind "$g_score")"; g_val="$(score_val "$g_score")"

    for tc in 2 4; do
        m_pair="$(run_score "setoption name Threads value ${tc}\n${POS[$name]}\ngo depth ${DEPTH}")"
        m_score="${m_pair%%|*}"; m_bm="${m_pair##*|}"
        [ "$m_bm" != "NONE" ] || fail "${name} Threads=${tc}: no/garbled bestmove"
        [ "$m_score" != "NONE" ] || fail "${name} Threads=${tc}: no score emitted"
        m_kind="$(score_kind "$m_score")"; m_val="$(score_val "$m_score")"
        [ "$m_kind" = "$g_kind" ] || fail "${name} Threads=${tc}: score kind ${m_kind} != ${g_kind} (st)"
        if [ "$g_kind" = "mate" ]; then
            # same mating side
            if { [ "$g_val" -lt 0 ] && [ "$m_val" -ge 0 ]; } || { [ "$g_val" -ge 0 ] && [ "$m_val" -lt 0 ]; }; then
                fail "${name} Threads=${tc}: mate sign flipped (${m_val} vs ${g_val})"
            fi
        else
            local_diff=$(( m_val - g_val )); [ "$local_diff" -lt 0 ] && local_diff=$(( -local_diff ))
            [ "$local_diff" -le "$BAND" ] || fail "${name} Threads=${tc}: cp ${m_val} vs st ${g_val} exceeds band ${BAND}"
        fi
    done
done

echo "mt-sanity: OK (${#ORDER[@]} positions, Threads {2,4} within band ${BAND} of single-thread, depth ${DEPTH})"
