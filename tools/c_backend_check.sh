#!/usr/bin/env bash
# Correctness oracle: build the engine through Zig's C backend and re-check the anchor.
#
# WHY THIS EXISTS. Zig leaves the in-memory layout of `@Vector` target-defined. Code that
# depends on a particular representation is therefore correct only by the grace of whichever
# backend it was compiled with, and every gate we have runs through LLVM -- so a wrong
# assumption is invisible to all of them. The C backend lowers the same constructs differently,
# which makes it the one cheap way to expose that class from outside.
#
# It has already earned its keep: the transform's non-zero-chunk mask was
# `@bitCast(@Vector(N, bool)) -> uN`, a movemask that is only correct when bool vectors are
# bit-packed. LLVM packs them (@sizeOf(@Vector(16,bool)) == 2); the C backend gives one byte per
# lane (sizeof == 16). Through LLVM the engine benched the anchor and every gate passed. Through
# C it benched 3062314, with the startpos eval off by one centipawn and every positional bucket
# wrong while psqt stayed exact. A wrong number, not a crash -- which is why nothing downstream
# could catch it.
#
# WHAT A FAILURE MEANS. A node-count mismatch here is a divergence between two lowerings of the
# same source. That is nearly always OUR bug -- a reliance on something the language does not
# guarantee -- not a backend bug. Diagnose it that way first: `eval` on a fixed position narrows
# it to psqt vs positional in one command.
#
# THIS IS NOT A PERFORMANCE PATH. The emitted C carries no vector types (the backend renders
# @Vector as a struct of scalars), so the result runs ~1.9x the instructions of the LLVM build.
# Use it to answer "is this correct", never "is this fast".
#
# Usage:  tools/c_backend_check.sh [arch]      # arch defaults to x86-64-sse41-popcnt
#
# Exit 0 when the C-lowered binary reproduces the anchor, non-zero otherwise.
set -u

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
ARCH="${1:-x86-64-sse41-popcnt}"
WORK="${WORK:-$(mktemp -d)}"

# Quote the anchor from build.zig, never from memory -- it moves on every bench-moving sync.
ANCHOR="$(grep -oE 'signature_ref orelse "[0-9]+"' "$REPO/build.zig" | grep -oE '[0-9]+')"
if [ -z "$ANCHOR" ]; then
    echo "c-backend: cannot read signature_reference from build.zig" >&2
    exit 1
fi
echo "c-backend: anchor $ANCHOR (from build.zig), arch $ARCH"

# 1. Emit C. The C backend cannot use LLD, so LTO must be off.
if ! zig build -Demit-c=true -Dlto=false -Darch="$ARCH" -p "$WORK/emit" >"$WORK/emit.log" 2>&1; then
    echo "c-backend: emit failed -- tail of $WORK/emit.log:" >&2
    tail -20 "$WORK/emit.log" >&2
    exit 1
fi
SRC="$WORK/emit/bin/stockfish.c"
[ -f "$SRC" ] || { echo "c-backend: no C emitted at $SRC" >&2; exit 1; }
echo "c-backend: emitted $(wc -l <"$SRC") lines of C"

# 2. The backend declares LLVM target intrinsics as extern symbols whose asm name is the
#    intrinsic itself (zig.h maps zig_mangled -> __asm("llvm.x86...")). Clang then sees a call to
#    `llvm.x86.*` with a struct-by-value signature and cannot select it. Strip the asm name so
#    they stay ordinary C symbols, and supply real implementations below.
python3 - "$SRC" "$WORK/patched.c" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
names = sorted(set(re.findall(r'zig_mangled\((llvm_x86_[a-z0-9_]+),', s)))
s = re.sub(r' zig_mangled\(llvm_x86_[a-z0-9_]+, "llvm\.x86\.[a-z0-9.]+"\)', '', s)
open(dst, 'w').write(s)
open(dst + '.intrinsics', 'w').write('\n'.join(names))
PY
mapfile -t NEEDED < "$WORK/patched.c.intrinsics"
echo "c-backend: intrinsics needing an implementation: ${NEEDED[*]:-none}"

# 3. Implement them with the equivalent immintrin builtins. Kept in its own translation unit:
#    the emitted C declares its own realpath, which collides with <stdlib.h> via immintrin.h.
#    Any intrinsic without a case here is a hard stop -- a silent miss would corrupt the eval,
#    which is exactly what this script exists to detect.
cat >"$WORK/intrin_shim.c" <<'EOF'
#include <stdint.h>
#include <string.h>
#include <immintrin.h>
struct vec_4_i32_78 { int32_t array[4]; };
struct vec_8_i16_70 { int16_t array[8]; };
struct vec_16_i8_58 { int8_t array[16]; };
struct vec_4_i32_78 llvm_x86_sse2_pmadd_wd(struct vec_8_i16_70 a0, struct vec_8_i16_70 a1) {
    __m128i x, y, r; struct vec_4_i32_78 out;
    memcpy(&x, a0.array, 16); memcpy(&y, a1.array, 16);
    r = _mm_madd_epi16(x, y);
    memcpy(out.array, &r, 16);
    return out;
}
struct vec_8_i16_70 llvm_x86_ssse3_pmadd_ub_sw_128(struct vec_16_i8_58 a0, struct vec_16_i8_58 a1) {
    __m128i x, y, r; struct vec_8_i16_70 out;
    memcpy(&x, a0.array, 16); memcpy(&y, a1.array, 16);
    r = _mm_maddubs_epi16(x, y);
    memcpy(out.array, &r, 16);
    return out;
}
EOF
for name in "${NEEDED[@]}"; do
    [ -z "$name" ] && continue
    if ! grep -q "\b$name\b" "$WORK/intrin_shim.c"; then
        echo "c-backend: no implementation for $name -- add one to this script (arch $ARCH)" >&2
        exit 1
    fi
done

# 4. Compile back. -flto lets clang inline the shims; without it every intrinsic is an
#    out-of-line call and the result is ~3x slower for reasons that are the harness's fault.
ZIGLIB="$(dirname "$(command -v zig)")/lib"
[ -d "$ZIGLIB" ] || ZIGLIB="$(zig env | grep -oE '"lib_dir": *"[^"]+"' | cut -d'"' -f4)"
if ! (cd "$WORK" && zig cc -O3 -flto -msse2 -msse3 -mssse3 -msse4.1 -mpopcnt \
        -I"$ZIGLIB" -o "$WORK/stockfish-c" patched.c intrin_shim.c \
        -lc -lm -lpthread >"$WORK/cc.log" 2>&1); then
    echo "c-backend: compile failed -- tail of $WORK/cc.log:" >&2
    tail -20 "$WORK/cc.log" >&2
    exit 1
fi

# 5. Bench from resources/ so the NNUE net resolves, and compare against the anchor.
GOT="$(cd "$REPO/resources" && "$WORK/stockfish-c" bench 2>&1 |
       sed -n 's/^Nodes searched  *: *\([0-9][0-9]*\).*/\1/p' | head -1)"
if [ "$GOT" != "$ANCHOR" ]; then
    echo "c-backend: MISMATCH -- C lowering benched $GOT, anchor is $ANCHOR" >&2
    echo "c-backend: the two lowerings disagree; suspect a representation this code assumes" >&2
    echo "c-backend: but Zig does not guarantee. Narrow it with \`eval\` on a fixed position:" >&2
    echo "c-backend: psqt correct + positional wrong points at the transform or the affine." >&2
    exit 1
fi
echo "c-backend: OK -- C lowering reproduces the anchor ($GOT)"
