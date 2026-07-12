#!/usr/bin/env bash
# Arch-variant bench-determinism sweep.
#
# The pure-Zig eval is integer-exact, hence arch-INVARIANT: every x86-64 tier must
# produce the same bench signature (node count) 2067208. Only sse41 (via
# `zig build parity`) and avx2 were gated before. This sweeps the wider tiers too
# -- bmi2 (PEXT + comptime-attacks codegen) and the host's best AVX-512 tier --
# which are exactly where the upcoming @Vector NNUE kernels could silently
# break bit-exactness at a wider vector width while sse41/avx2 stay green. It runs
# the REAL bench per tier (`zig build signature` fails on any mismatch), so it is
# not a hollow gate.
#
# Only tiers the HOST can execute are run -- you cannot bench instructions the CPU
# lacks. avx2 and bmi2 are gated on their /proc/cpuinfo flags; the host's own best
# tier (scripts/get_native_properties.sh, the detector the build itself uses) is by
# definition runnable. A dev box reporting avx512icl runs {avx2,bmi2,avx512icl}; a
# CI runner without AVX-512 just runs {avx2,bmi2}. sse41 is left to `zig build
# parity`. NOT wrapped in a `zig build` step: it invokes `zig build` per tier, and
# nesting those under an outer build would contend on the same cache lock.
#
# Usage: arch_determinism.sh [signature-ref]   (default 2067208; run from anywhere)
set -u

REF="${1:-2067208}"
REPO="$(git rev-parse --show-toplevel)" || exit 1
cd "$REPO" || exit 1
CPUINFO="${GP_CPUINFO:-/proc/cpuinfo}"

declare -A DONE
fail=0
run_tier() {  # $1 = arch tier
    [ -n "${DONE[$1]:-}" ] && return
    DONE[$1]=1
    echo "arch-determinism: $1 ..."
    local out rc
    out="$(zig build signature -Darch="$1" -Dsignature-ref="$REF" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "arch-determinism: $1 OK ($REF)"
    else
        echo "arch-determinism: $1 FAILED -- signature != $REF or build/run error:" >&2
        printf '%s\n' "$out" | tail -6 >&2
        fail=1
    fi
}

grep -qw avx2 "$CPUINFO" 2>/dev/null && run_tier x86-64-avx2
grep -qw bmi2 "$CPUINFO" 2>/dev/null && run_tier x86-64-bmi2
HOST="$(sh "$REPO/scripts/get_native_properties.sh" 2>/dev/null)"
case "$HOST" in
    x86-64-*) run_tier "$HOST" ;;
    *) echo "arch-determinism: host tier '${HOST:-?}' is not an x86-64 tier -- skipping host sweep" ;;
esac

if [ "${#DONE[@]}" -eq 0 ]; then
    echo "arch-determinism: no runnable tier above the sse41 baseline (that one is covered by \`zig build parity\`)"
    exit 0
fi
if [ "$fail" -eq 0 ]; then
    echo "arch-determinism: OK (${#DONE[@]} tier(s) all == $REF)"
else
    echo "arch-determinism: FAIL -- a tier diverged from $REF (arch-dependent codegen broke bit-exactness)" >&2
    exit 1
fi
