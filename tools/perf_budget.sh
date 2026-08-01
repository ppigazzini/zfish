#!/usr/bin/env bash
# Absolute retired-instruction budget -- the regression class every other gate is blind to.
#
# The bench signature proves the same NODE count. It says nothing about how many x86
# instructions those nodes cost, so a refactor can shed no nodes, keep every golden green,
# and still run measurably slower. That is a time-domain divergence, it costs Elo, and
# until now nothing in this tree could fail on it: the perf_counters A/B ratio needs a
# second binary to compare against and cancels the absolute out, and nps cannot resolve
# below ~5% (docs/08-idiomatic-zig.md).
#
# Retired instructions are near-deterministic, which is what makes an ABSOLUTE budget
# gateable where a cycle count is not: measured spread on this box is 0.00063% across six
# runs of `bench 16 1 8` (1,680,144,344 .. 1,680,154,925). The default tolerance below is
# ~300x that, so it fires on a real change and never on noise.
#
# LOCAL-ONLY, and deliberately NOT in `zig build parity`:
#   * perf_event_open is refused in many CI containers, and a gate that cannot run there
#     would either be a permanent skip or a permanent red.
#   * The count is TOOLCHAIN-specific. A Zig upgrade legitimately moves it, and so does an
#     intended perf change -- re-derive with `perf-budget-update` and say so in the commit.
#
# Being local-only carries a known failure mode this repo has already paid for: tb-cursed
# sat red for seven days on an UNMODIFIED binary because nothing ran it. Run this by hand
# after a toolchain bump or a perf commit, the same discipline docs/09-tooling-ci.md asks
# for the other local-only gates.
#
# A SKIP IS NOT A PASS. If perf_event_open is unavailable this exits 127, not 0, so a
# caller testing the exit code cannot mistake "could not measure" for "did not regress".
#
# Usage:
#   tools/perf_budget.sh [check|update]
#   ARCH=x86-64-avx512icl tools/perf_budget.sh update   # add/refresh another tier
#   ROUNDS=9 TOLERANCE_PCT=0.10 tools/perf_budget.sh
set -uo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
MODE="${1:-check}"
# Pin the tier by default rather than building native: an instruction count is a property
# of the BINARY, so a fixed -Darch keeps the golden comparable across hosts sharing a
# toolchain, where a native build would re-key it to whatever CPU happened to run it.
ARCH="${ARCH:-x86-64-sse41-popcnt}"
ROUNDS="${ROUNDS:-5}"
# 0.05%: ~50x the measured run-to-run spread (0.001%), and TIGHT ENOUGH TO FIRE. The first
# value tried here was 0.20%, which mutation-testing rejected -- making the per-node
# adjustKey50 call non-inline costs +0.0876% and sailed through it while the node signature
# stayed green, i.e. the gate passed the exact regression it exists to catch. A tolerance
# is only meaningful against a measured noise floor and a measured regression, not by feel.
TOLERANCE_PCT="${TOLERANCE_PCT:-0.05}"
BENCH="${BENCH:-bench 16 1 8}"
GOLDEN="$REPO/tools/instr_budget.golden"

case "$MODE" in
check | update) ;;
*)
    echo "perf-budget: unknown mode '$MODE' (want check|update)" >&2
    exit 2
    ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Build the engine at the pinned tier and the measuring tool beside it.
( cd "$REPO" && zig build "-Darch=$ARCH" ) >/dev/null 2>&1 || {
    echo "perf-budget: engine build failed for $ARCH" >&2
    exit 2
}
( cd "$REPO" && zig build-exe tools/perf_counters.zig -OReleaseFast \
    -femit-bin="$WORK/perf_counters" ) >/dev/null 2>&1 || {
    echo "perf-budget: perf_counters build failed" >&2
    exit 2
}

# Measure from resources/: the net is an external runtime input and the engine SIGSEGVs on
# a null net anywhere else, which would read here as a measurement failure.
OUT="$( cd "$REPO/resources" && "$WORK/perf_counters" --budget "$REPO/zig-out/bin/stockfish" \
    "$ROUNDS" $BENCH 2>&1 )"
LINE="$(printf '%s\n' "$OUT" | grep -E '^budget nodes=' | tail -1)"

if [ -z "$LINE" ]; then
    echo "perf-budget: SKIPPED -- no counter reading (perf_event_open unavailable?)" >&2
    printf '%s\n' "$OUT" | tail -3 >&2
    echo "perf-budget: a skip is NOT a pass; exiting 127 so nothing reads it as one" >&2
    exit 127
fi

NODES="$(printf '%s' "$LINE" | sed -n 's/.*nodes=\([0-9]*\).*/\1/p')"
INSTR="$(printf '%s' "$LINE" | sed -n 's/.*instructions=\([0-9]*\).*/\1/p')"

if [ -z "$NODES" ] || [ -z "$INSTR" ] || [ "$INSTR" = "0" ]; then
    echo "perf-budget: unparseable reading: $LINE" >&2
    exit 2
fi

if [ "$MODE" = "update" ]; then
    [ -f "$GOLDEN" ] || {
        cat > "$GOLDEN" <<'HDR'
# zfish retired-instruction budget: median count over `bench 16 1 8`, per ARCH tier.
# Deterministic to ~0.001%; TOOLCHAIN-specific -- re-derive on a Zig upgrade or an
# intended perf change, and say which in the commit. A regression that leaves the node
# signature untouched shows up ONLY here. One line per arch: <arch> <nodes> <count>.
HDR
    }
    # Rewrite this arch's line, keep every other tier's.
    tmp="$WORK/golden"
    grep -v -E "^$ARCH " "$GOLDEN" > "$tmp" 2>/dev/null || true
    printf '%s %s %s\n' "$ARCH" "$NODES" "$INSTR" >> "$tmp"
    # Header first, then the tiers sorted, so the file has one canonical order.
    { grep -E '^#' "$tmp"; grep -v -E '^#|^$' "$tmp" | sort; } > "$GOLDEN"
    echo "perf-budget: wrote $ARCH -> $INSTR instructions ($NODES nodes)"
    exit 0
fi

[ -f "$GOLDEN" ] || {
    echo "perf-budget: no golden yet -- run 'tools/perf_budget.sh update' to record one" >&2
    exit 127
}

WANT_LINE="$(grep -E "^$ARCH " "$GOLDEN" | tail -1)"
if [ -z "$WANT_LINE" ]; then
    echo "perf-budget: SKIPPED -- $GOLDEN carries no line for $ARCH" >&2
    echo "perf-budget: a skip is NOT a pass; exiting 127" >&2
    exit 127
fi

WANT_NODES="$(printf '%s' "$WANT_LINE" | awk '{print $2}')"
WANT_INSTR="$(printf '%s' "$WANT_LINE" | awk '{print $3}')"

# Guard the workload before the number. A count taken over a different tree is not a
# comparison at all -- the same reason the A/B path refuses when node counts differ.
if [ "$NODES" != "$WANT_NODES" ]; then
    echo "perf-budget: FAIL -- node count moved: golden $WANT_NODES, measured $NODES" >&2
    echo "perf-budget: that is a SEARCH change, not a perf one; fix the signature first" >&2
    exit 1
fi

DELTA_PCT="$(awk -v a="$INSTR" -v b="$WANT_INSTR" 'BEGIN { printf "%.4f", (a - b) * 100.0 / b }')"
OVER="$(awk -v d="$DELTA_PCT" -v t="$TOLERANCE_PCT" 'BEGIN { print (d > t) ? 1 : 0 }')"
UNDER="$(awk -v d="$DELTA_PCT" -v t="$TOLERANCE_PCT" 'BEGIN { print (d < -t) ? 1 : 0 }')"

printf 'perf-budget: %s  %s nodes  golden %s  measured %s  delta %s%%  (tolerance +/-%s%%)\n' \
    "$ARCH" "$NODES" "$WANT_INSTR" "$INSTR" "$DELTA_PCT" "$TOLERANCE_PCT"

if [ "$OVER" = "1" ]; then
    echo "perf-budget: FAIL -- retired instructions REGRESSED beyond tolerance." >&2
    echo "perf-budget: the node count is unchanged, so no other gate can see this." >&2
    echo "perf-budget: if the cost is intended, re-derive with perf-budget-update and" >&2
    echo "perf-budget: carry the measurement in the commit body (AGENTS.md perf ledger)." >&2
    exit 1
fi

if [ "$UNDER" = "1" ]; then
    # An improvement is not a failure, but a stale budget stops gating: say so loudly.
    echo "perf-budget: OK -- and IMPROVED beyond tolerance. Re-derive with"
    echo "perf-budget: perf-budget-update so the budget keeps holding the new floor."
    exit 0
fi

echo "perf-budget: OK -- within tolerance"
exit 0
