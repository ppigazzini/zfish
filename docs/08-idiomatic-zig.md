# Idiomatic, fast Zig in zfish

The patterns this codebase uses to be fast, portable, and provably correct at once.
Follow them when adding to the hot path or the build. Each pairs a technique with the
gate that keeps it honest — a claim with no gate is a wish.

The enabling invariant is the bench signature: any change that holds it is
behaviour-preserving, so the aggressive techniques below are safe to attempt because
one command decides whether behaviour moved. See the golden rule in
[CONTRIBUTING](../CONTRIBUTING.md). Judge every gate by its exit code, not its log
text.

## Vectorize integer hot loops by hand — the toolchain will not

A scalar integer loop stays scalar. Measured on this toolchain, an `i32` reduction —
`for (a) |v| s += v` — emits **zero** vector instructions, where the identical loop
compiled from C through `zig cc` emits a full AVX2 reduction. Same bundled LLVM, same
`-mavx2`. It is not aliasing (a read-only dot product fails identically) and not the
overflow flags (the emitted IR carries `add nsw`); the loop is unrolled but never
widened. Every form behaves the same: pointer or slice, `+` or `+%`, signed or
unsigned.

The cause is not a flag you can flip: running clang's own `-O3` pipeline on the LLVM IR
that `zig build-obj` *emits* still produces zero vector ops. Zig emits IR the loop
vectorizer will not take, so no build option enables it and re-optimizing does not help.

A chess engine is integer math end to end, so this is the load-bearing rule of the hot
path: **any per-element integer loop that should be SIMD must be written as `@Vector`,
because nothing downstream will do it for you.** The measured cost is real — fusing the
8-bucket psqt accumulator update from a scalar loop into one `@Vector(8, i32)` cut its
instructions, and the scalar form would have stayed scalar forever.

This is the single biggest way zfish diverges from Stockfish. Upstream leaves these
loops scalar in the source and the C++ compiler widens them at `-O3`; zfish must widen
them by hand. So the performance grind is not "add another intrinsic" — it is closing
exactly the auto-vectorization gap the toolchain withholds. See
[the philosophy note](README.md#where-zfish-diverges-from-stockfish).

```zig
// Not this — stays scalar, one lane per iteration:
for (removed) |i| { var b: usize = 0; while (b < 8) : (b += 1) acc_mem[b] -= w[i * 8 + b]; }

// This — one 256-bit register, all rows applied in-register:
var acc: @Vector(8, i32) = target[0..8].*;
for (removed) |i| acc -= @as(@Vector(8, i32), (w + i * 8)[0..8].*);
target[0..8].* = acc;
```

The same rule catches **fills**, which are easy to overlook. `@memset` covers a zero
or byte-repeating fill, but a table cleared to a non-zero `i16` (a history default like
`-5`) is not a byte pattern, so `for (dst) |*e| e.* = -5` stays a scalar store loop. A
broadcast `@Vector` store vectorizes it — and it is race-free wherever the fill is an
exclusive phase (a per-worker or striped clear), so it needs no atomics even if the
table is atomic during search:

```zig
const V = 32;
const vv: @Vector(V, i16) = @splat(-5);
var i: usize = 0;
while (i + V <= dst.len) : (i += V) dst[i..][0..V].* = vv;
while (i < dst.len) : (i += 1) dst[i] = -5; // scalar tail
```

Note a corollary: making a shared table `@atomic` for search-time races also makes its
*clear* scalar, because an atomic store never vectorizes. Keep the clear on a plain
view of the same memory when it runs in an exclusive phase.

## Reach for `@Vector` before hand-written SIMD

The NNUE feature transformer is written once in portable `@Vector` code. LLVM lowers
it to AVX-512, AVX2, or SSE on x86 and to NEON on aarch64. Reach for an intrinsic only
where the portable form leaves measurable throughput behind: the affine layers add
comptime x86 specializations (`nnue_inference.zig`) over the same `@Vector` fallback,
and every path is bit-identical.

```zig
const V = @Vector(16, i16);
const acc: V = a + b; // vpaddw on AVX2, vaddw on NEON — the backend's job
```

The integer-exact eval is arch-invariant, so every specialization must yield the same
bench. `tools/arch_determinism.sh` runs the real bench on each tier the host can
execute and asserts they agree — `zig build parity` gates the single arch it is given.

## Translate an intrinsic instead of reaching for one

Upstream writes its hot kernels in x86 intrinsics, one path per ISA. Most have a portable Zig
form that lowers to the same instruction, so an intrinsic declaration is the last resort. The
mapping worth knowing before touching a kernel:

**Memory.** Alignment is a property of the pointer, not the operation:

| C++ | Zig | note |
| --- | --- | --- |
| `_mm256_load_si256` / `_mm256_store_si256` | `ptr[d..][0..V].*` on an `align(64)` buffer | aligned move |
| `_mm256_loadu_si256` / `_mm_loadu_si128` | the same expression on an unaligned pointer | unaligned move; there is no separate spelling |
| `_mm_loadl_epi64` | `@as(@Vector(8, u8), buf[i..][0..8].*)` | partial load |
| `_mm_cvtsi32_si128` / `_mm_cvtsi128_si32` | `@bitCast` between a scalar and a 1-lane vector, or `v[0]` | scalar/vector move |

**Constants and reinterpretation.** All free — type-level, no instruction:

| C++ | Zig |
| --- | --- |
| `_mm256_setzero_si256` / `_mm512_setzero_epi32` | `@splat(0)` |
| `_mm512_set1_epi8` / `_epi16` / `_epi32` | `@splat(x)` — the lane type comes from the destination |
| `_mm256_castsi256_ps`, `_mm256_castsi256_si512` | `@bitCast` between equal-width vectors |
| `_mm256_extracti128_si256`, `_mm512_inserti64x4` | `@shuffle` with comptime indices |

**Arithmetic.** The vector add/sub intrinsics **wrap** (2's-complement); the `_adds_`/`_subs_`
forms **saturate**. Zig has a dedicated operator for each, and using the plain `+`/`-` instead
is a silent correctness change — a ReleaseSafe overflow panic (ReleaseFast UB) where the
intrinsic would wrap:

| C++ | Zig |
| --- | --- |
| `_mm256_add_epi16` / `_epi32`, `_mm256_sub_epi16` / `_epi32` (wrapping) | `a +% b`, `a -% b` |
| `_mm_adds_epi8` / `_mm_subs_epi8` (saturating) | `a +| b`, `a -| b` |
| wrapping scalar arithmetic (2's-complement) | `a +% b`, `a -% b`, `a *% b` |
| `_mm_mulhi_epi16` | `@intCast((@as(Vu32, a << s7) * @as(Vu32, b)) >> s16)` — LLVM matches the mulhu pattern |
| `_mm_madd_epi16`, `_mm_maddubs_epi16`, `_mm512_dpbusd_epi32` | `extern fn @"llvm.x86…"` declarations — no portable form |
| `_mm_min_epi16` + `_mm_max_epi16` (ClippedReLU) | `@max(lo, @min(hi, v))` |
| `_mm512_reduce_add_epi32` | `@reduce(.Add, v)` |

**Shifts.** The shift amount is a vector whose lane type is sized to the shifted width — `u4`
for 16-bit lanes, `u5` for 32-bit. A wrong width is a compile error, not a slow path:

| C++ | Zig |
| --- | --- |
| `_mm_slli_epi16` / `_mm_srli_epi16` | `v << s`, `v >> s` on unsigned lanes |
| `_mm_srai_epi16` (arithmetic) | `v >> s` on **signed** lanes — signedness picks the instruction |

**Width conversion.** Widening and narrowing are `@intCast`; the saturating narrows are
distinct instructions and Zig reaches them by casting from a saturated value:

| C++ | Zig |
| --- | --- |
| `_mm_cvtepi8_epi16` (sign-extend widen) | `@intCast` to a wider signed lane |
| `_mm_packs_epi16` / `_mm_packs_epi32` (signed saturate) | `@intCast` after `@max`/`@min` clamping |
| `_mm_packus_epi16` / `_mm_packus_epi32` (unsigned saturate) | same, clamped to the unsigned range |
| `_mm512_cvtsepi32_epi16`, `_mm512_cvtsepi16_epi8` | `@intCast` on a clamped vector |
| `_mm_unpacklo_epi8` / `_mm_unpackhi_epi8`, `_mm_shuffle_epi32`, `_mm_shufflelo_epi16` | `@shuffle` with comptime index vectors |

**Comparison and masks.** Zig comparisons on vectors yield `@Vector(N, bool)`, which has no
guaranteed memory layout — consume it with `@select`/`@reduce`, never `@bitCast` it (see below):

| C++ | Zig |
| --- | --- |
| `_mm_cmpeq_epi8`, `_mm_cmpgt_epi8` / `_epi32` | `a == b`, `a > b` |
| `_mm512_cmpgt_epi32_mask`, `_mm512_test_epi32_mask` | the same comparison; the mask is the bool vector |
| `_mm256_movemask_epi8`, `_mm_movemask_ps` | `@reduce(.Or, @select(Mask, cond, lane_bits, zeros))` |

**Bit and scalar:**

| C++ | Zig |
| --- | --- |
| `_tzcnt_u64` / `__builtin_ctzll` | `@ctz` |
| `__builtin_popcountll` | `@popCount` |
| `alignas(64)` | `align(64)` |

**No portable equivalent — the known gap.** `_mm512_maskz_compress_epi16` / `_epi32` and
`_mm512_mask_compressstoreu_epi16` (`vpcompress`) have no Zig builtin and no pattern LLVM
infers. Upstream uses them to compact its non-zero-chunk indices on AVX-512; this codebase has
no equivalent path and walks a bitset on every tier instead. Anything needing lane compaction
has to declare the intrinsic or restructure around it.

Two entries above read as ordinary code and are not.

**A typed slice copy is a vector load.** No intrinsic, no cast:

```zig
const Vi16 = @Vector(V, i16);
var acc: Vi16 = source.ptr[d..][0..V].*;   // one aligned load
acc -= (weights + row)[d..][0..V].*;       // one subtract
target.ptr[d..][0..V].* = acc;             // one aligned store
```

`[0..V]` is what does it: fixing the length at comptime makes the result a `*[V]T`, so the
deref is a vector move rather than a loop.

**Reach a specific instruction through an `extern` LLVM intrinsic, never inline assembly.**
Inline asm is opaque to the optimizer and blocks inlining across the call; a declared intrinsic
participates in normal optimization:

```zig
const vpdpbusd512 = struct {
    extern fn @"llvm.x86.avx512.vpdpbusd.512"(
        @Vector(16, i32), @Vector(16, i32), @Vector(16, i32),
    ) @Vector(16, i32);
}.@"llvm.x86.avx512.vpdpbusd.512";
```

## Build tables and lane patterns at comptime

Where C++ needs a `constexpr` function or a generated header, Zig computes the table in a
`comptime` block beside its use, so the values and the code that consumes them cannot drift:

```zig
const lane_bits: Vgm = comptime blk: {
    var w: [groups_per_step]GMask = undefined;
    for (&w, 0..) |*bit, i| bit.* = @as(GMask, 1) << @intCast(i);
    break :blk w;
};
```

Three supporting builtins matter here. `@Int(.unsigned, N)` constructs an integer type of
exactly `N` bits, so a mask type tracks a lane count instead of being hardcoded.
`@setEvalBranchQuota` raises the comptime evaluation budget — the feature-index tables need it,
and the failure without it is a compile error, not a wrong answer. `@compileError` in a
`comptime` block rejects an invalid width or layout at build time rather than producing a
kernel that silently computes the wrong thing.

## Keep unrolled accumulators comptime-indexed

The affine kernel splits its dot product into several independent dependency chains, because
a single accumulator serialises the layer behind one high-latency instruction. The chains
live in an array of vectors, and **the index into that array must be `comptime`**:

```zig
inline for (0..chains) |ch| {           // comptime — stays in registers
    inline for (0..chunks) |c| {
        acc[ch * chunks + c] = dot(acc[ch * chunks + c], a, b);
    }
}
```

Written with a runtime counter instead, `acc` needs an address, so it spills to memory and
every accumulator round-trips per group — which costs more than the chains win. This is why
the loop is unrolled rather than counted, and it constrains any rewrite: a restructuring that
makes the chain index runtime is not a refactor, it is a regression.

## Set vector width deliberately, per tier

`@Vector(N, T)` is `N * @sizeOf(T)` bytes on every target — the width does not adapt. A
512-bit vector is one register on AVX-512 and **four registers plus lane-repacking shuffles**
on SSE. Widths here are hand-set constants, and the right value differs by tier and by loop:
the feature transform and the accumulator row ops each carry their own, because sweeping them
independently found different optima. Treat a width constant as tuned for the tier it was
measured on, and re-measure before assuming it transfers.

## Dispatch ISA tiers at comptime, from one source

The `-Darch` tiers build from the same code; arch-specific choices are `comptime`
branches keyed on the target, not preprocessor forks. `build.zig` declares the
tiers; the source stays single. Comptime specialization only stays correct if CI
**builds every tier** — one nobody compiles rots silently — so CI compiles them and
runs the real bench per tier.

## Allocate statically on the hot path

The busy files — `search_driver`, `search_main`, `movepick`, `move_do`,
`nnue_accumulator` — allocate nothing. Long-lived arenas (transposition table,
history stats, NNUE weights) are allocated once at setup through a single injected
allocator and reused; the per-node path touches only stack and pre-sized buffers.
Decide memory at startup, not per operation.

## Return large hot-path structs by pointer or out-param, not by value

This toolchain does not apply return-value optimization across a non-inlined call: a
function that builds a large struct in a local and returns it by value compiles to a
`memcpy` of the whole struct into the caller's slot, once per call. On the per-node
path that is a per-node copy, and it hides in a profile as a `memcpy` symbol rather
than a hot function. Return a `*const T` for a view into memory that already outlives
the call, or fill a caller-owned `result: *T` out-param for a freshly built one — the
NNUE feature and threat path (`nnue_feature.zig`, `nnue_acc_layout.zig`) returns both
ways. Removing two such returns cut the bench's `memcpy` from 3.4% of instructions to
0.8%. The gate is the signature — the returned bytes are unchanged — plus a
`perf_callgrind.sh` `costs` sweep to confirm `memcpy` actually fell; see
[09-tooling-ci](09-tooling-ci.md). The mirror caveat is real: a by-value return that
the optimizer inlines costs nothing, so verify the returner is a live symbol in the
profile before rewriting it.

## Break import cycles with a composition root, not a god module

Zig permits import cycles, so a strict DAG is a choice. Make it with a composition
root and dependency injection through function pointers rather than a shared
mega-module — the structure is described in
[ARCHITECTURE](00-architecture.md#the-composition-root-and-the-cycle-break-hooks).
The price is real: a function pointer is an optimizer barrier and its erased
`*anyopaque` context costs type safety, so `zig build hook-lint` bounds the hooks.
Reach for this to invert a *specific* upward dependency, not as a default.

## Never assume a `@Vector`'s memory layout

Zig leaves vector layout **target-defined**. `@bitCast`ing a `@Vector(N, bool)` to an
`N`-bit integer looks like the obvious movemask, and `@bitSizeOf` agrees the sizes match — but
it is only correct where bool vectors are bit-packed. LLVM packs them
(`@sizeOf(@Vector(16, bool)) == 2`); Zig's C backend gives one byte per lane (`sizeof == 16`),
an 8x disagreement that silently reads a few lanes' bytes as the whole mask.

Build bool-vector results from `@select` and `@reduce`, which have defined semantics:

```zig
const nonzero = values != @as(V, @splat(0));
const mask: Mask = @reduce(.Or, @select(Mask, nonzero, lane_bits, no_bits));
```

`std.simd` constructs every one of its bool-vector results this way — `firstTrue`,
`lastTrue`, `countTrues` — and never bitcasts one. The engine's feature transformer did, and
paid for it: the mask was correct under LLVM and wrong under any other lowering, which is a
wrong evaluation rather than a crash. `tools/c_backend_check.sh`
([09-tooling-ci.md](09-tooling-ci.md)) exists to catch that class. The defined form cost about
1% of instructions on the hottest path in the engine, measured — cheap for not depending on a
representation nobody promised.

## Write cross-version Zig with comptime shims

Where a std API differs between supported Zig versions, one comptime branch reads
whichever the running compiler exposes and prunes the other — a comptime-known `if`
drops the untaken branch from analysis, so an absent field never trips a compile
error:

```zig
const root = if (@hasField(std.Build, "build_root"))
    (b.build_root.path orelse ".")
else
    (b.root.root_dir.path orelse ".");
```

Two companions: prefer a builtin that survives renames (`@Int(.unsigned, n)` over a
std wrapper), and prefer the modern form even when the old one still parses
(`@splat(0)` over `[_]u8{0} ** N`). A non-blocking CI lane builds under Zig master so
a future break surfaces early instead of at the next toolchain bump.

## Reserve computed-goto for unpredictable dispatch

`movepick.nextMove` is the engine's hottest dispatcher: a plain `switch` on
`state.stage`. It stays a plain switch on purpose. A labeled `switch` (computed goto)
pays off when the next state is data-driven and the branch predictor cannot guess it;
a staged move picker advances through its stages in order, so the predictor already
has them and the computed goto only defeats it. Nothing in this tree uses a labeled
switch — that is the decision, not an omission.

## Measure differentially, before attributing

`tools/perf_counters.zig` is the local A/B gate over CPU hardware counters, and it
encodes the method: interleave the two builds and take the median of the per-round
paired ratios (not the ratio of the medians — they disagree), pin the run, and assert
the node counts match so the comparison is the same work. It refuses to report when
those preconditions fail.

**Attribute cost with `tools/perf_fingerprint.py compare`, never by reading a profile
line.** callgrind emits one entry per *(origin-file, function)* pair -- inlined code is
attributed to the file it came from, under the caller's name -- so one logical function
appears as many lines and its true cost is the sum across all of them. C++ is hit harder
than Zig because upstream's work lives in headers. Reading one line per side once turned a
real 0.99x parity into a reported "1.87x, the worst component". The tool sums each group
and reconciles against callgrind's own `PROGRAM TOTALS`, so it fails loudly instead of
printing a plausible lie. `docs/09-tooling-ci.md` has the runnable sequence.

Follow the same discipline by hand: to claim a component is the bottleneck, ablate it
— stub it out, hold everything else fixed, measure the delta. Control the confounds
first (inlining across a comparison boundary; comparing the same search tree rather
than two different ones). Label a hypothesis as a hypothesis. A performance claim
ships with the command that produced it. It is a LOCAL gate — perf counters are not
available in CI, so it never runs there.
