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

**No portable equivalent — and here, deliberately not reached for.**
`_mm512_maskz_compress_epi16` / `_epi32` and `_mm512_mask_compressstoreu_epi16`
(`vpcompress`) have no Zig builtin and no pattern LLVM infers, so reaching them needs a
declared intrinsic like the dot-product ones above. Upstream uses them to compact its
non-zero-chunk indices into a flat `u16` list on AVX-512. This codebase records a bitset
instead and pops it with `@ctz`, and that is a measured choice rather than an unclosed gap:
the affine kernels hoist the input and weight base pointers once per 64-group word and index
with a word-local offset, which a flat list of absolute indices undoes. Building the list at
the transform was implemented and measured as an instruction *regression*, because the
per-chunk compress, store and popcount bookkeeping costs more than a flat consumer read
saves against the hoisted walk. Upstream has no hoisted alternative, which is why the same
shape pays for it and not for us. Anything needing lane compaction still has to declare the
intrinsic — but check whether the consumer already has a cheaper access pattern first.

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

## Keep memory safety where the input is not yours

Zig gives spatial safety through bounds-checked slices and temporal safety through a
checking allocator — but **the shipped binary is ReleaseFast, so by default it checks
nothing**: no bound, no cast, no overflow, no alignment. That is the right default for a
per-node search kernel and the wrong one everywhere the bytes came from outside. The rule
is therefore not "turn safety on" or "leave it off", it is: *safety is a property you
place, and every placement needs a reason and a gate.*

Two inputs are not zfish's: the `.nnue` file named by `EvalFile`, and the Syzygy
`.rtbw`/`.rtbz` files under `SyzygyPath`. Both are parsed with cursors advanced by values
read out of the files themselves. Everything below follows from that.

| Rule | How this tree holds it | Gate |
| --- | --- | --- |
| **Raise `@setRuntimeSafety(true)` over untrusted parses.** The scope is lexical — it does not follow calls, so it goes on each function. | The `.nnue` section framing (`readLebSection`, `parseFeatureTransformer`, `parseLayer`, `dstSlice`) and the Syzygy header parse (`table_load.set`, `setDtzMap`, `decode.setSizes`). | `signature` (bytes unchanged) |
| **…and price it before you place it.** A check on a per-byte loop is not free. | `decodeLeb` is deliberately excluded: +22.8% of a whole `bench 16 1 5` instruction count versus +0.1% for the framing, and its every access is bounded by a test it states itself. | `perf_counters.zig` |
| **Prefer slices to `[*]` at every input boundary.** A many-item pointer carries no length, so neither the producer nor the consumer can check one. | `PairsData`'s file-backed fields are slices; the parse carves them with a bounded `take`. The ~220 remaining `[*]` are hot NNUE/search kernels where the pointer is the calling convention, plus the erased hook seams — none of them reads a file. | `tb-*` goldens |
| **Validate once at load, not once per use.** | `setSizes` checks every btree child in one O(n) pass, which makes `probe.setSymLen`'s writes in-bounds by construction and leaves the probe path free of the check. | `decode.zig` unit tests |
| **Check what the header could not pin, at the point of use.** | `block` and `sym` in `decompressPairs` are decoded from the payload, so the header cannot bound them; they are checked there and bail to 0. | Syzygy fuzz target |
| **…and what the header could not pin BECAUSE THE POSITION IS NOT KNOWN AT LOAD.** | `doProbeTable`'s group walk is driven by `group_len[]`, derived from the file's piece nibbles, while `squares` comes from the position — so a corrupt table asks for a group the position never filled, and the column goes negative. Refused at the probe, which already answers that way for a table it cannot read. | `fuzz_probe.zig` |
| **Port C's wrapping arithmetic as wrapping.** `+`/`-` trap in safe modes where upstream's `uint64_t` is defined to wrap; on corrupt input that difference is a crash, not a hardening. | The canonical-Huffman recurrence uses `+%`/`-%`; the region widths use `*|` so an absurd size stays absurd instead of wrapping into a satisfiable one. | Syzygy fuzz target |
| **Poison uninitialized arenas in the safe modes.** | `memory.poison_uninitialized` fills large-page blocks with `0xAA` in Debug **and ReleaseSafe** — Debug alone is dead code here, because `zig build -Doptimize=Debug` SEGVs the Zig 0.16 compiler. | ReleaseSafe engine benches 2508687 |
| **Let a checking allocator own the error paths.** | `std.testing.allocator` and `checkAllAllocationFailures` (19 sites). It earns this: the leak on every `error.CorruptTable` path in `setSizes` was found the moment a corrupt-table test existed, not by reading the code. | `test`, `parity-valgrind` |
| **Fuzz the boundary, and assert the boundary — not the answer.** | `src/platform/syzygy/fuzz_targets.zig` asserts every region stays inside its buffer; a garbage table is *allowed* to decode to garbage. Built ReleaseSafe so a missed bound trips a check. | `zig build fuzz --fuzz` |
| **Validate a file's claim against something derived WITHOUT the file.** A parse that only checks a header against itself accepts any self-consistent lie. | `table_load.set` tests the pawnful table's leading piece against the lead colour the registry derived from the material configuration — from the filename enumeration, never from a byte of the file. Without it a flipped nibble left the leading group empty and the probe indexed the pawn geometry with a square it never wrote. | `tb-*` goldens, `fuzz_probe.zig` |
| **Fuzz the CONSUMER too, not only the parser.** A unit target cannot see an invariant that only the code downstream of it relies on: a header it accepts can still be one the probe cannot survive. | `fuzz_probe.zig` parses an image into a registered `TBTable`, publishes it by hand so no file is opened, and probes — fixture-free, because a target guarded on tables that are absent skips silently and reads exactly like a clean run. | `zig build fuzz --fuzz` |
| **Keep `catch unreachable` to cases the CODE proves, not ones the current data happens to satisfy.** The parity harness had eight of them formatting FENs out of a case table into a hand-sized buffer: provable only for the table as written, so one longer FEN was a silent overrun. They report through `fail` now. What is left in `src/` formats values whose maximum width the type or the notation fixes — an integer, a hex key, a rendered move — into a buffer sized past it. | review, and ReleaseSafe on every tool that judges the engine |

The order matters. Bounds that are checkable from a header belong at load, where they cost
nothing and can *reject*; only what the payload decides belongs at the point of use, where
the best available answer is to refuse. A trap is the floor, not the goal — panicking on a
malformed tablebase is better than reading past it, and worse than reporting the table as
missing, which is what `mapped`/`mappedDtz` now do.

**What is deliberately not done.** `std.valgrind` client requests are absent: the shipped
allocator is `posix_memalign`, which memcheck already tracks, so annotating the headless
`page_alloc` fallback would gate nothing the `parity-valgrind` lane does not. Search
threads take `std.Thread`'s default stack; recursion is bounded by `MAX_PLY`, and a guard
page catches the overflow Zig's absent stack probes would not. Neither is a gap someone
should close without new evidence.

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
The price is real but bounded: a function pointer is an optimizer barrier and its
erased `*anyopaque` context costs type safety, so `zig build hook-lint` bounds the
hooks. The barrier only costs *where the pointer is called*, so the discipline is to
keep every hook off the per-node path — measured, none sit there, and the DAG is free
on the hot path (Zig is whole-module, so `@import` is not an inlining boundary; this
does not even need LTO). See
[Does the DAG cost performance?](00-architecture.md#does-the-dag-cost-performance).
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

**Never `@bitCast` an `extern struct`.** An extern struct's padding bits are not defined
by the language, so the newer compiler rejects the cast outright — and it rejects it even
where a `comptime` block asserts every `@offsetOf` and the `@sizeOf`, because the rule is
about the type, not the instance. `extern` is still the right way to *pin field order* for
a layout a SIMD kernel loads by position; what it does not buy is a whole-struct bitcast.
Compose and decompose the lanes field by field instead — it costs nothing, since the shift
and or fold into the same move the bitcast emitted:

```zig
// Not this — pins the layout correctly, then casts in a way only one compiler accepts:
return @bitCast(e);

// This — same instruction, same bytes, accepted by both:
const move_lane: u32 = @as(u32, e.raw_move) | (@as(u32, e.reserved) << 16);
return .{ @bitCast(move_lane), e.value };
```

The field-by-field form is byte-order-dependent where the bitcast was not, so assert the
endianness in a `comptime` block rather than leaving it implied. Arrays are unaffected —
`@bitCast` between `[8]u8` and a `u64` stays legal.

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

**A ratio needs a second binary; a budget does not.** `tools/perf_budget.sh` holds this
tree's own retired-instruction count on `bench 16 1 8` to `tools/instr_budget.golden`,
keyed by arch tier. It exists because the bench signature proves the same *node* count and
says nothing about what those nodes cost, so a change can shed no nodes, keep all 36 gates
green, and still run measurably slower — the one regression class nothing else here can
fail on. Instructions are near-deterministic (measured spread 0.00063% over six runs),
which is what makes an absolute budget gateable where a cycle count is not.

The tolerance is 0.05%, about 50x that spread, and it was **not** chosen by feel: the first
value tried was 0.20%, and mutation-testing rejected it — making the per-node `adjustKey50`
call non-inline costs +0.0876% with the node signature still green, so the gate passed the
exact regression it exists to catch. Pick a tolerance against a measured noise floor *and*
a measured regression.

It is LOCAL-ONLY and not in `zig build parity`: `perf_event_open` is refused in many CI
containers, and the count is toolchain-specific, so a Zig upgrade legitimately moves it.
Re-derive with `tools/perf_budget.sh update` and carry the measurement in the commit body.
A skip exits **127**, never 0, so "could not measure" cannot be read as "did not regress" —
and being local-only it carries the staleness failure mode `docs/09-tooling-ci.md` records
for `tb-cursed`, so run it by hand after a toolchain bump or a perf commit.

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
ships with the command that produced it.

**An ablation must reach every entry point, and the node count is what tells you it
did.** Pricing the incremental accumulator meant forcing a refresh in `evaluateSide` —
which left the shared-suffix route (`forwardUpdateBoth`) still walking incrementally, so
the records the companion ablation dropped were still being read on that path. The
instruction count came back plausible either way; the node count came back 162,860
instead of 163,081, and that is the only reason the hole was visible. Ablate behind a
`comptime` flag and re-assert the signature, not just the delta. It is a LOCAL gate — perf counters are not
available in CI, so it never runs there.

**Know each instrument's blind spots before trusting its verdict.**

- **Each of `perf_counters`' five axes has its own floor, and three of them cannot
  resolve a percent.** Measured by A/A control — the icl build against a byte-identical
  copy of itself, 20 rounds, both orientations, reported as the same `sqrt(fwd/swp)`
  a real comparison would use:

  | axis | A/A reading | usable below 1%? |
  | --- | --- | --- |
  | instructions | exact, 1.000 | **yes** — spread ~6k in 14.5 billion |
  | branch misses | 0.997 / 1.001 → 0.999 | **yes** — floor ~0.2% |
  | cycles | 0.986 / 0.999 → 0.9935 | no |
  | IPC | 1.014 / 1.001 → 1.0065 | no |
  | cache misses | 0.983 / 1.014 → 0.9846 | no — widest of the five |

  Swapping orientations does **not** rescue the cycle axis: an A/A pair still reads
  0.9935 after cancellation, so the bias correction removes the position effect and
  leaves the run-to-run floor untouched. A sub-1% cycle, IPC or cache-miss claim cannot
  be certified here at any round count — quote it as "not resolvable", not as a result,
  and do not read a sign off it. Adjudicate small deltas on instructions or branch
  misses, or with a fastchess Elo match (concurrency = physical cores, idle box,
  `Timeouts:` near zero — a concurrent build forfeits games exactly like SMT
  oversubscription).
- The branch-miss axis is the newest — `perf_counters` collected the counter for a long
  time without printing it, so any conclusion in this tree dated before that fix saw
  four axes, not five. It is where the **wide tiers' deficit against the oracle shows
  up**: on identical trees zfish leads on instructions at every tier (0.961–0.979) yet
  trails on branch misses at the AVX-512 ones (vnni512 1.154, avx512icl 1.192) while
  sse41 and avx2 sit at 0.981/0.987, and avx2 instead carries the cache-miss outlier
  (1.112). So the residue behind a flat cycle ratio is not one thing — it is a
  different thing per tier.
- **A branch-miss ratio does not say WHY, so read it against the branch count.**
  `perf_counters` now reports retired branches and the miss rate beside the misses. More
  misses can mean the code executes more branches or predicts the same ones worse, and
  those call for opposite fixes — reshape the code, or break a data dependence. Equal
  miss *rates* with a high branch ratio is branch **density**, not misprediction, and
  reaching for a prediction fix there is wasted work. The counters are stable enough to
  read: an A/A run of the same binary gives a branch ratio of 1.000 and rates of 0.914%
  against 0.918%.
- **Exclude startup before reading any callgrind total.** A whole-process run of
  `bench 16 1 3000` is roughly half startup: `readLebSection` alone is ~32% of zfish's
  instructions and `read_parameters` ~34% of the oracle's, with magic-table init and
  `memset` behind them. A total taken that way says zfish parses the net faster than
  C++ iostreams, which earns no Elo, and it inverted the sign of a search comparison
  here twice in one session. Toggle collection on the search entry instead:

  ```sh
  valgrind --tool=callgrind --cache-sim=yes --collect-atstart=no \
    --toggle-collect='search_id_loop.iterativeDeepening' \
    ./stockfish bench 16 1 3000 default nodes
  # oracle: --toggle-collect='Stockfish::Search::Worker::iterative_deepening()'
  ```

  Verify the two runs searched one tree (same nodes at every depth) before comparing.
- **A stall deficit can be layout, not code — and alignment is invisible to every other
  axis.** Search-only, startup excluded, zfish once trailed the oracle by 20.6% on LL
  data misses and 53% on LL write misses while executing 1.7% *fewer* instructions.
  The cause was `WorkerLayout.histories` declaring `align(8)`, which let the block sit
  24 bytes into a cache line; `align(64)` cut LL write misses 63.3% and LL data misses
  12.1% with the instruction count moving 0.0003%. Alignment removes no work, so the
  signature, every golden, `perf_counters`' instruction axis and callgrind's Ir column
  all read identical across the fix. When cycles disagree with instructions, probe
  layout with a comptime offset check before hunting for code:

  ```zig
  comptime { @compileError(std.fmt.comptimePrint("{d}", .{ @offsetOf(T, "f") % 64 })); }
  ```

  Attribute such a win to cache-set conflict unless a control says otherwise: aligning
  the tables *inside* an already-aligned block bought 0.13%, so line straddling was not
  the mechanism — relocating the block was.
- **A plain struct's field order is not yours to reason about, and a big embedded array
  can split a scalar cluster you never touched.** `WorkerLayout` interleaved `nodes` /
  `tb_hits` / `best_move_changes` (written every node) with `sel_depth` / `optimism` /
  `root_depth` / `root_delta` (read every node) — not because either group moved, but
  because Zig's descending-alignment sort placed `root_pos` (1064 B) and `root_state`
  (192 B) between them, ~1.8 KB of nothing either scalar cluster needs. Giving `root_pos`,
  `root_state`, `root_moves`, `limits` and `last_iteration_pv` their own `align(64)`
  (matching the arenas' existing tier) opts each out of the plain `align(8)`/`align(4)`
  classes the scalars sort into, so the two scalar clusters close the gap without moving
  either by name. Verified by reading `@offsetOf` for every field off a built binary's
  DWARF info, not by inspecting source order — a plain struct's declared order and its
  memory order are unrelated facts. No measured cycle claim is attached (mcfish's own
  port of this exact fix reported the same: direction not established at its sample
  size) — this is a fidelity fix, done on the same footing as the `histories` alignment
  above: it makes the layout deterministic instead of a compiler ordering choice.
- **TBD — the LL instruction-miss gap, and what is not known about it.** On the
  search-only profile above, zfish takes ~3.7× the oracle's LL instruction misses
  (166 385 vs 45 109) while taking *fewer* L1I misses (4.29 M vs 5.58 M), and neither
  alignment fix moved it. That is the largest remaining outlier in the profile.

  What is measured: those counts, at x86-64-avx2, on one 147 106-node workload,
  single-threaded, on one tree. Nothing else.

  What is **not** measured, and must not be asserted until it is:

  - whether it costs any cycles at all. No cycle or Elo measurement attributes anything
    to it. "Fewer L1I misses but more reaching DRAM implies scattered hot code" is a
    hypothesis with a plausible story, not a finding.
  - whether callgrind's cache model applies. It simulates a fixed two-level hierarchy,
    not this box's cache, and it models no prefetcher. Every LL figure in this section —
    including the ones justifying the alignment fix — inherits that caveat. The
    alignment fix carries an independent wall-clock check; this gap carries none.
  - whether it explains the wide tiers' deficit attributed per tier above. Those tier
    numbers come from `perf_counters` on whole-bench totals, a different instrument on a
    different workload. Treat that attribution as provisional.

  Before anyone attempts a fix: get a cycle-level attribution that this gap costs
  something. Absent that, the honest statement is that zfish misses instruction cache
  more often than the oracle in one simulator, on one tier, for unknown cost.
- **Do not promote a bench-metric ratio over the instruction axis for predicting Elo.**
  A 4-tier × 3-TC matrix against the pinned oracle (12 000 games) ranks the tiers by
  Elo in exactly the order of their instruction ratios (Spearman +1.00); branch misses
  and cycles rank at +0.80, IPC and cache misses at +0.40. That is n = 4 and a perfect
  rank happens by chance 1 time in 24, and the tier-to-tier Elo gaps are themselves
  only 1–1.6σ — so treat it as "no axis has earned the right to displace instructions",
  not as a law.
- callgrind's simulation **ignores software prefetch on both engines** — the
  `@prefetch`/`_mm_prefetch` lines carry Ir but zero data refs, so no callgrind
  bar can certify a prefetch change, for or against.
- The hardware instruction counter retires an ERMS `rep stosb`/`rep movsb` as
  **one instruction regardless of size** — memset/memcpy work is invisible to
  `perf_counters`' instruction axis. Gate memset-sensitive changes (large-page
  fills, TT clears) on callgrind Ir, which counts the expansion.
- Stall-class token counters (PRF/scheduler, `tools/perf_stalls.zig`) carry a
  **±6.5% A/A floor** — far wider than cycles. Only deltas ≥15% are decidable
  at 12 rounds; run an A/A control for every new counter set before trusting
  any A/B delta on it.
- callgrind's SIGILL is **AVX-512-only** — sse41 and avx2 both profile fine.
  Do not extrapolate avx2 conclusions from sse41 profiles when the avx2 tier
  can be measured directly.
- An instruction-count win can still be a cycle **loss** (recurred three times:
  register-pressure spills, memory-traffic growth, layout resampling). Cycles at
  the tier that actually runs decide, subject to the floor above.
- A profile-group regex is a **hypothesis about symbol names**: upstream
  `do_move`'s signature contains `TranspositionTable const*`, and inlining puts
  the same logic under different symbols per side. Verify group membership
  per-symbol before trusting any component ratio.
