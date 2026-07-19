# Idiomatic, fast Zig in zfish

The patterns this codebase uses to be fast, portable, and provably correct at once.
Follow them when adding to the hot path or the build. Each pairs a technique with the
gate that keeps it honest — a claim with no gate is a wish.

The enabling invariant is the bench signature: any change that holds it is
behaviour-preserving, so the aggressive techniques below are safe to attempt because
one command decides whether behaviour moved. See the golden rule in
[CONTRIBUTING](../CONTRIBUTING.md). Judge every gate by its exit code, not its log
text.

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

Upstream writes its hot kernels in x86 intrinsics, one path per ISA. Most of them have a
portable Zig form that lowers to the same instruction, so the intrinsic is the last
resort, not the first. The mapping worth knowing before touching a kernel:

| C++ intrinsic | Zig | lowers to |
| --- | --- | --- |
| `_mm256_load_si256` / `_mm256_store_si256` | `ptr[d..][0..V].*` — a typed slice copy | `vmovdqa` |
| `_mm256_setzero_si256` | `@splat(0)` | `vpxor` |
| `_mm512_set1_epi16` | `@splat(x)` | `vpbroadcastw` |
| `_mm256_add_epi32` / `_mm256_sub_epi16` | `a + b` / `a - b` | `vpaddd` / `vpsubw` |
| `_mm_min_epi16` + `_mm_max_epi16` | `@max(lo, @min(hi, v))` | `vpminsw` / `vpmaxsw` |
| `_mm_srai_epi16` | `v >> @as(@Vector(V, u4), @splat(n))` | `vpsraw` |
| `_mm_packs_epi16` | `@intCast` to a narrower lane type | `packsswb` |
| `_mm_unpacklo_epi8` / `_mm_shuffle_epi32` | `@shuffle` with comptime indices | `punpcklbw` / `pshufd` |
| `_mm256_movemask_epi8` | `@select` + `@reduce(.Or, …)` — see the layout section below | `pmovmskb` |
| `_mm_mulhi_epi16` | `@intCast((@as(Vu32, a << s7) * @as(Vu32, b)) >> s16)` | `pmulhuw` |
| `_tzcnt_u64` / `__builtin_popcountll` | `@ctz` / `@popCount` | `tzcnt` / `popcnt` |
| `template<int N>` | a `comptime` parameter | full specialization |
| `#pragma unroll` | `inline for` | unrolled, index comptime |

Two of these are worth spelling out, because they read as ordinary code and are not.

**A typed slice copy is a vector load.** There is no intrinsic and no cast:

```zig
const Vi16 = @Vector(V, i16);
var acc: Vi16 = source.ptr[d..][0..V].*;   // one aligned load
acc -= (weights + row)[d..][0..V].*;       // one subtract
target.ptr[d..][0..V].* = acc;             // one aligned store
```

`[0..V]` is what does it: fixing the length at comptime makes the result a `*[V]T`, so the
deref is a vector move rather than a loop.

**Reach a specific instruction through an `extern` LLVM intrinsic, never inline assembly.**
Inline asm is opaque to the optimizer and blocks inlining across the call; the declared
intrinsic participates in normal optimization:

```zig
const vpdpbusd512 = struct {
    extern fn @"llvm.x86.avx512.vpdpbusd.512"(
        @Vector(16, i32), @Vector(16, i32), @Vector(16, i32),
    ) @Vector(16, i32);
}.@"llvm.x86.avx512.vpdpbusd.512";
```

`@bitCast` between equal-width vectors costs nothing — it is a type-level reinterpret — so
wrapping such an intrinsic in a typed helper is free.

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
