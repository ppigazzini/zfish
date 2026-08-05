#!/usr/bin/env bash
# Arch-variant bench-determinism sweep.
#
# The pure-Zig eval is integer-exact, hence arch-INVARIANT: every x86-64 tier must
# produce the same bench signature (node count) 2508687. Only sse41 (via
# `zig build parity`) and avx2 were gated before. This sweeps the wider tiers too
# -- bmi2 (PEXT + comptime-attacks codegen) and the AVX-512 rungs -- which are exactly
# where the @Vector NNUE kernels could silently break bit-exactness at a wider vector
# width while sse41/avx2 stay green. It runs the REAL bench per tier (`zig build
# signature` fails on any mismatch), so it is not a hollow gate.
#
# THE TIER LIST IS THE LADDER, not a sample of it: every x86-64 tier `build/arch.zig`
# accepts above the sse41 baseline, in the order `tools/native_arch.zig` resolves them.
# Assembling the list from cpuinfo probes instead yields the tiers THIS BOX has, and it
# lost `x86-64-avxvnni` exactly that way -- a tier the build supports and `native` can
# resolve to, which nothing here had ever compiled.
#
# BUILDING AND BENCHING ARE SEPARATE QUESTIONS, so ask them separately:
#
#   BUILD   every tier, on every host. A tier that stops COMPILING -- a @Vector width the
#           backend rejects, a feature macro gone stale -- needs no ISA to catch, so a
#           host that cannot execute it can still catch it.
#   BENCH   only where the CPU can execute what the tier emits. A build at
#           -Darch=x86-64-vnni512 emits AVX-512 wherever it was built, so benching it on
#           a host without AVX-512 raises SIGILL -- a fact about the runner, not about
#           determinism. ../rfish's 9564e86 died there when its own sweep first drew a
#           mixed hosted fleet.
#
# A TIER THIS HOST CANNOT DRIVE IS NAMED, NOT COUNTED. The anchor is then unasserted for
# it, so the sweep reports SKIPPED and exits 2 -- "could not measure" must not read as
# "did not regress", which is the same rule tools/perf_budget.sh follows. `--host-tiers`
# accepts that reduced coverage and exits 0, still printing every hole. The flag is the
# allowance's OWNER: it sits at the call site where a reader meets it, it expires by
# itself (a runner that gains AVX-512 benches the whole ladder and it excuses nothing),
# and it launders no FAILURE -- a tier that builds and then benches the wrong number
# exits 1 with or without it.
#
# NOT wrapped in a `zig build` step: it invokes `zig build` per tier, and nesting those
# under an outer build would contend on the same cache lock.
#
# Usage: arch_determinism.sh [signature-ref] [--host-tiers]   (default 2508687)
set -u

REF=""
ACCEPT_PARTIAL=0
for a in "$@"; do
    case "$a" in
        --host-tiers) ACCEPT_PARTIAL=1 ;;
        -*)
            echo "arch-determinism: unknown flag '$a' (want [signature-ref] [--host-tiers])" >&2
            exit 2
            ;;
        *) REF="$a" ;;
    esac
done
REF="${REF:-2508687}"

REPO="$(git rev-parse --show-toplevel)" || exit 1
cd "$REPO" || exit 1
CPUINFO="${GP_CPUINFO:-/proc/cpuinfo}"

# tier -> the /proc/cpuinfo flags the host needs to EXECUTE it, naming the same feature
# sets tools/native_arch.zig resolves `native` through. Two parallel arrays rather than
# one associative array, so the ladder keeps its order in the report. Mind the kernel's
# spelling: it prints avx512bw and avx512vl without an underscore but avx512_vnni,
# avx512_vbmi2, avx512_bitalg and avx512_vpopcntdq with one.
TIERS=(x86-64-avx2 x86-64-bmi2 x86-64-avxvnni x86-64-avx512 x86-64-vnni512 x86-64-avx512icl)
NEEDS=(
    "avx2"
    "bmi2"
    "avx_vnni"
    "avx512f avx512bw"
    "avx512_vnni avx512dq avx512f avx512bw avx512vl"
    "avx512f avx512cd avx512vl avx512dq avx512bw avx512ifma avx512vbmi avx512_vbmi2 avx512_vpopcntdq avx512_bitalg avx512_vnni vpclmulqdq gfni vaes"
)

# The x86-64 ladder is not this host's ISA at all: every tier would be cross-built and
# none could be benched, so there is nothing here to assert. Say so before building.
HOST="$(zig build host-arch 2>/dev/null)"
case "$HOST" in
    x86-64-*) ;;
    *)
        echo "arch-determinism: host tier '${HOST:-?}' is not x86-64 -- the whole ladder would be"
        echo "arch-determinism: cross-built and unrunnable, so nothing here can assert the anchor."
        if [ "$ACCEPT_PARTIAL" = "1" ]; then
            echo "arch-determinism: --host-tiers given; zero coverage accepted on this host."
            exit 0
        fi
        echo "arch-determinism: SKIPPED -- exit 2 (a skip is NOT a pass)" >&2
        exit 2
        ;;
esac

# Name the flags the host is short of, so the report says WHY a tier went unbenched.
missing_flags() {  # $1 = space-separated cpuinfo flags
    local f out=""
    for f in $1; do
        grep -qw "$f" "$CPUINFO" 2>/dev/null || out="$out $f"
    done
    printf '%s' "$out"
}

fail=0
benched=0
UNRUNNABLE=()

for i in "${!TIERS[@]}"; do
    tier="${TIERS[$i]}"

    # BUILD, unconditionally: this is the half that needs no ISA.
    if ! out="$(zig build "-Darch=$tier" 2>&1)"; then
        echo "arch-determinism: $tier FAILED TO BUILD:" >&2
        printf '%s\n' "$out" | tail -6 >&2
        fail=1
        continue
    fi

    missing="$(missing_flags "${NEEDS[$i]}")"
    if [ -n "$missing" ]; then
        echo "arch-determinism: $tier BUILT, NOT benched -- this host lacks:$missing"
        UNRUNNABLE+=("$tier")
        continue
    fi

    echo "arch-determinism: $tier ..."
    if out="$(zig build signature "-Darch=$tier" "-Dsignature-ref=$REF" 2>&1)"; then
        echo "arch-determinism: $tier OK ($REF)"
        benched=$((benched + 1))
    else
        echo "arch-determinism: $tier FAILED -- signature != $REF or run error:" >&2
        printf '%s\n' "$out" | tail -6 >&2
        fail=1
    fi
done

# A mismatch outranks a hole and no flag reaches it: a tier that built and then benched
# the wrong number is a broken invariant, not reduced coverage.
if [ "$fail" -ne 0 ]; then
    echo "arch-determinism: FAIL -- a tier did not build, or diverged from $REF" >&2
    echo "arch-determinism: (arch-dependent codegen broke bit-exactness)" >&2
    exit 1
fi

if [ "${#UNRUNNABLE[@]}" -ne 0 ]; then
    echo "arch-determinism: $benched of ${#TIERS[@]} tiers benched $REF; all ${#TIERS[@]} built."
    echo "arch-determinism: unasserted on this host: ${UNRUNNABLE[*]}"
    if [ "$ACCEPT_PARTIAL" = "1" ]; then
        echo "arch-determinism: --host-tiers given; the hole above is accepted, not closed."
        exit 0
    fi
    echo "arch-determinism: SKIPPED -- the anchor is unasserted for the tiers named above." >&2
    echo "arch-determinism: exit 2 (a skip is NOT a pass). Pass --host-tiers to accept it." >&2
    exit 2
fi

echo "arch-determinism: OK ($benched of ${#TIERS[@]} tiers built AND benched $REF)"
exit 0
