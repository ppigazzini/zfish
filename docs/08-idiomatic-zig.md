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

A **decay** is the same shape with a correctness step attached. `ageMainHistory`'s
`v * 729 / 1024` stays scalar for the reason above; widening it means sign-extending a
block of `i16` to `i32`, scaling, and truncate-dividing in registers. What makes that
rewrite legal is the rounding: `@divTrunc` by a power of two rounds toward zero exactly as
the scalar form does — not toward negative infinity — and LLVM lowers a constant divisor
to bias-and-shift rather than a division, so the written values are bit-identical. Make
that argument explicitly before widening a decay — a rounding-mode slip is a behaviour
change, not a speedup, and it is the one thing this rewrite can silently get wrong.

Route every such fill through `shared_history.fillI16Slice` rather than re-spelling the
loop per table. One lane width to tune, and a new table cannot silently stay scalar.

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

Pick the narrow whose **saturation subsumes a clamp you are already paying for**. The
feature transform owes its output a `max(0, ·)` and a narrow, and one `vpackuswb`
(`nnue_transform_packus.zig`) supplies both, because saturating to zero *is* the clamp —
worth two `vpmaxsw`, two `vpmovwb` and a `vinserti64x4` per 64 output bytes, an emitted
loop of 96 operations per perspective instead of 120, and a 5.8% smaller
`evaluateBucketRaw`. Both axes matter: the body shrinks as well as the work.
Two conditions make that legal to do. State the bit-exactness argument (here: a signed
`vpmulhw` carries the sign into the product, `vpackuswb` saturates it to zero, and a
positive product never saturates since `(255 << 7) * 255 >> 16 == 127`) and pin it with a
scalar-reference test over the edge values. And gate on **the CPU feature that owns the
instruction** — `avx512bw`, not the tier name — since a tier gate that happens to imply it
today is a gate on the wrong thing.

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

## Assert alignment at the load site, not on the declaration

Alignment is a property of the pointer — and Zig loses it at the first runtime offset.
Slicing a many-item pointer degrades the result to the **element** alignment, so
`(weights + row)[d..][0..V].*` on a `[*]const i16` is an `align(2)` load in the type
system however the buffer was allocated. That is free on AVX2 and AVX-512, whose VEX and
EVEX encodings fold an unaligned operand — and expensive on the 128-bit tier, where a
non-VEX SSE op folds a load into its `m128` operand only when 16-byte alignment is
*provable*. The whole `sse41` tier paid a separate `movdqu` per 16 weight bytes where
upstream's `alignas(64)` weights fold straight into every `pmaddubsw`/`paddw`/`pminsw`.

Declaring `align(64)` on the parameter does not survive the offset. Restore it at each
load instead — `nnue_acc_rowops.zig`'s `loadVec` and `nnue_affine.zig`'s `loadW`:

```zig
const q: *align(A) const [V]i16 = @alignCast(@ptrCast(p + off));
return q.*;
```

The cast costs nothing in ReleaseFast and is a **checked** assertion in ReleaseSafe,
which is what keeps it honest: every caller's offset is a multiple of `A` by layout, and
the safe build proves it rather than the comment claiming it.

The limit is which tier pays. On a `perf_callgrind.sh` run over one tree, restoring the
alignment moves whole-program Ir **−6.04%** at `x86-64-sse41-popcnt` — ratio against the
oracle 1.062 to 0.998 — and nothing at avx2 or avx512, which read flat to four decimal
places. So a whole-program ratio that looks healthy on three tiers can carry a
six-percent defect on the fourth, and no ratio names which one: diff the disassembly of
the kernel per tier, where upstream's `pmaddubsw 0x80(%rdx,%r8,1)` reads against zfish's
`movdqu`+`movdqa`+`pmaddubsw`. **The addressing mode is part of the kernel — read the
operands, not just the mnemonics.**

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

**The chain count is the same kind of knob.** How many independent accumulator chains the
affine splits into is tuned per ISA exactly like a width — three at AVX-512-VNNI, where
`vpdpbusd`'s latency needs them, and two at AVX2, whose narrower accumulators are cheaper
to keep live (measured −16.7M instructions there, with the other tiers comptime-untouched
because they never instantiate that arm).

**Wider is not monotone, and the failure modes differ by direction.** Above the tuned
value the tile stops fitting: 256 lanes at AVX2 measured as an instruction win and a
**cycle loss**, because 16 `ymm` cannot hold the tile plus the widen transient and the
extra memory traffic outweighs the removed instructions. Above that again the cost moves
to the front end: a 512-lane row tile at AVX-512 is a real −3.4% instruction win that does
**not** land, because using 16 `zmm` instead of 32 leaves LLVM no registers to unroll the
row loop by two and `applyCombined`'s body grows 51% — an instruction win paid for in
instruction *fetch*. Sweep a width on cycles at the tier that runs, and read the emitted
body size, not only the instruction axis.

**A falsified width is falsified in a context, so re-take one only when you can name what
moved.** The AVX2 apply tile carries 128 lanes against two `perf_counters` sweeps of that
same knob that read against it, and what separates the readings is the register and
traffic pressure around the tile — the arena, the routing and the transform body all
changed between them — not the sweep. The rule that makes this safe rather than a
licence: state the context change first, predict the direction, and require the result to
clear the noise floor by a margin (this one reads instructions 0.937, six times the
floor). "Try it again" is not a method.

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

## Leave a fully-written buffer `undefined`

A zero-init the producer overwrites is a dead store, and the optimizer removes it only
where it can see the writer — across a call, through a pointer, or into an arena it
cannot, so the write is real work. Both scales cost real instructions on the bench. Per
node: the accumulator update's scratch is `undefined`, worth 4.18% of instructions, and
`evaluateBucketRaw`'s 128-byte `concat` likewise, because the four activations fill every
byte before `fc_1` reads one. At startup: `memory` hands out large-page blocks
uninitialized, since the net parse, `resizeState`'s clear and worker construction rewrite
them — which holds the bench's `memset` self-cost at 107.8 M instructions rather than
424.6 M (`perf_callgrind.sh`, one tree).

The condition is `undefined` **where a producer provably writes every byte before any
read**, and it is the proof that makes it safe rather than the pattern: the feature-
transformer arena is tiled gaplessly by the parse, pinned by a `comptime` assertion in
`nnue_parse.zig` so a dimension change cannot open a padding gap. Where a fill is
load-bearing it stays — `resizeState` must clear the table it resizes, and no gate here
can see otherwise, none of them having a clock; the sibling port that dropped it measured
roughly 90–118 Elo.

The limit: reading `undefined` is Illegal Behaviour and the shipped ReleaseFast build
checks nothing, so the detector lives in the safe modes. `memory.poison_uninitialized`
fills those blocks with `0xAA` in Debug and ReleaseSafe, so a read-before-write fails
loudly instead of riding whatever the heap held.

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
| **Poison uninitialized arenas in the safe modes.** | `memory.poison_uninitialized` fills large-page blocks with `0xAA` in Debug **and ReleaseSafe** — Debug alone is dead code here, because `zig build -Doptimize=Debug` SEGVs the Zig 0.16 compiler. | ReleaseSafe engine benches the anchor |
| **Let a checking allocator own the error paths.** | `std.testing.allocator` and `checkAllAllocationFailures` (19 sites). It earns this: the leak on every `error.CorruptTable` path in `setSizes` was found the moment a corrupt-table test existed, not by reading the code. | `test`, `parity-valgrind` |
| **Fuzz the boundary, and assert the boundary — not the answer.** | `src/platform/syzygy/fuzz_targets.zig` asserts every region stays inside its buffer; a garbage table is *allowed* to decode to garbage. Built ReleaseSafe so a missed bound trips a check. | `zig build fuzz-tb --fuzz` |
| **Validate a file's claim against something derived WITHOUT the file.** A parse that only checks a header against itself accepts any self-consistent lie. | `table_load.set` tests the pawnful table's leading piece against the lead colour the registry derived from the material configuration — from the filename enumeration, never from a byte of the file. Without it a flipped nibble left the leading group empty and the probe indexed the pawn geometry with a square it never wrote. | `tb-*` goldens, `fuzz_probe.zig` |
| **Fuzz the CONSUMER too, not only the parser.** A unit target cannot see an invariant that only the code downstream of it relies on: a header it accepts can still be one the probe cannot survive. | `fuzz_probe.zig` parses an image into a registered `TBTable`, publishes it by hand so no file is opened, and probes — fixture-free, because a target guarded on tables that are absent skips silently and reads exactly like a clean run. | `zig build fuzz-tb-probe --fuzz` |
| **Keep `catch unreachable` to cases the CODE proves, not ones the current data happens to satisfy.** The parity harness had eight of them formatting FENs out of a case table into a hand-sized buffer: provable only for the table as written, so one longer FEN was a silent overrun. They report through `fail` now. What is left in `src/` formats values whose maximum width the type or the notation fixes — an integer, a hex key, a rendered move — into a buffer sized past it. | review, and ReleaseSafe on every tool that judges the engine |

The order matters. Bounds that are checkable from a header belong at load, where they cost
nothing and can *reject*; only what the payload decides belongs at the point of use, where
the best available answer is to refuse. A trap is the floor, not the goal — panicking on a
malformed tablebase is better than reading past it, and worse than reporting the table as
missing, which is what `mapped`/`mappedDtz` now do.

**What is deliberately not done.** `std.valgrind` client requests are absent: everything
memcheck can see it already tracks, so annotating the headless `page_alloc` fallback would
gate nothing the `parity-valgrind` lane does not. The one thing memcheck stopped seeing is
the Linux large-page arena, which now comes from `mmap` rather than `posix_memalign`
([06-platform.md](06-platform.md)); `memory.liveLargePageBlocks()` and its unit test carry
that coverage instead, because a client request would only re-describe a mapping the
allocator already has the length of. Search
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
[10-tooling-ci](10-tooling-ci.md). The mirror caveat is real: a by-value return that
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

## Reach for a sized enum, not a wrapper struct, when a space needs a type

Zig's newtype over an integer is a sized enum: `enum(u2)` where the space is closed and
the tag width is the array bound, `enum(u32) { _ }` where it is open. It has the layout
of its tag, is opened by `@intFromEnum` and closed by `@enumFromInt`, and adds nothing
at runtime. `encode.TbFile` is the instance in the tree.

**Which spaces deserve one, what it costs, and what it does not stop are the neighbouring
page's subject — [09-type-design.md](09-type-design.md), including
[the cost rule](09-type-design.md#the-cost-rule).** Read it before adding a type. What
belongs here is the four mechanical facts about doing it in *this* language:

- **There is no operator overloading.** A newtype over a quantity that is computed with —
  a score, a depth, a Zobrist key — becomes a method call at every arithmetic site. That
  is a large, diff-hostile change on top of a runtime cost the cost rule predicts, so the
  usual answer is to type the *accessor* instead of the value: `pawnCorrEntry` welds a key
  to the counter it selects without wrapping the key at all.
- **There is no niche packing for optional enums.** `?E` is one byte wider than `E` even
  when `E` leaves tag values unused, so wrapping a sentinel in an optional costs space
  rather than saving it. `sq_none = 64` in
  [board_core.zig](../src/engine/board/board_core.zig) stays in-band for that reason,
  matching upstream.
- **`@enumFromInt` into an open enum is not range-checked.** The pattern stops a confusion,
  never an intent, so it is not a substitute for a bound.
- **A path-imported file belongs to exactly one module.** A type shared across module
  boundaries must be a named module in [build/modules.zig](../build/modules.zig) with an
  edge from each reader — `nnue_dimensions` is one — and then named in
  `src/engine/headless.zig` and declared as a dep on every standalone test root that
  reaches it. A path import from a second module is a compile error, not a warning, and
  `zig build parity` goes green on the other two while `zig build test` is red.

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
([10-tooling-ci.md](10-tooling-ci.md)) exists to catch that class. The defined form cost about
1% of instructions on the hottest path in the engine, measured — cheap for not depending on a
representation nobody promised.

## Write cross-version Zig with comptime shims

zfish builds on Zig **0.16.0**, the required toolchain, and a non-blocking CI lane builds
it under a pinned Zig master snapshot so a future break surfaces early instead of at the
next toolchain bump. Where a std API differs between the two, one comptime branch reads
whichever the running compiler exposes and prunes the other — a comptime-known `if` drops
the untaken branch from analysis, so an absent field never trips a compile error.

**Every such branch lives in `build/config.zig`, and callers call it.** That is the rule,
not a preference, and it is the one this repo learned by breaking. The shim below existed
and was correct; two later sites re-derived it inline anyway — `lanes.zig` reached for
`b.build_root.path`, `structural.zig` for `b.build_root.handle` — and both landed green,
because 0.16 (the compiler every contributor runs) has that field. The master lane was red
from the commit that added them.

```zig
// build/config.zig — the ONLY file that may name either field.
pub fn repoPath(b: *std.Build, sub: []const u8) []const u8 { ... }  // a path
pub fn repoDir(b: *std.Build) std.Io.Dir { ... }                    // a handle
```

Both shims answer the same 0.16-vs-master split (`build_root: Cache.Directory` against
`root: Cache.Path`), so both belong to the same owner; a caller that needs the directory
handle rather than the path must not open a second branch for it. `zig build
build-version-lint` refuses a bypass, and runs inside `parity`.

**A `std.Build` break is a CONFIGURE error, and that is what makes it expensive.**
`build()` never finishes, so *every* step of that lane dies at once — exe, test, fuzz,
every arch tier — and the log names a file nobody edited. There is no partial signal to
read and no single step to bisect to. So **any `build.zig` or `build/` edit re-opens the
master lane**, exactly the way a `src/platform/` edit forces a cross-compile: build it
under the pinned snapshot before committing. Source-only edits are the cheap case; build
edits are not.

The APIs that differ, each with the spelling that works on both:

| Instead of | Use | Why |
| --- | --- | --- |
| `b.build_root.path` / `b.root.root_dir.path` | `config.repoPath(b, sub)` | 0.16 and master disagree on the field |
| `b.build_root.handle` | `config.repoDir(b)` | same split, and `handle` is an `Io.Dir` on both |
| `b.pathFromRoot(x)` | `config.repoPath(b, x)` | removed |
| `b.getInstallPath(.bin, …)` | `run.addArtifactArg(exe)` | removed. **Absolutize it** if the step re-spawns from another cwd: it yields an absolute path on 0.16 and a build-root-relative one on master |
| `b.args` (the `zig build … -- args` passthrough) | a `-D` string option, tokenized | **There is no shim.** Master's `Build` has no equivalent field, so `@hasField`-guarding it compiles and then silently DROPS the flags while still exiting 0 — a step that runs at defaults and reports a pass over a smaller sample than its log claims |
| `std.meta.Int(sign, bits)` | `@Int(sign, bits)` | a builtin survives std renames |
| `[_]u8{0} ** N` | `@splat(0)` | master rejects `**` after `}`/`)` and its own `zig fmt` mangles it to `* *`. Nested: `@splat(.{...})`; a repeated string: `++ @as([N]u8, @splat('A'))` |

**Pin the master snapshot; never float it.** A floating `master` makes the lane flap on
upstream's in-flight work rather than on our regressions, and the lane is only worth
having if a red means *us*. Bump the pin by hand after building under that exact compiler
locally. Two things to expect while doing it: master carries genuine in-flight churn
(the optimize-mode enum was being renamed from `ReleaseFast` to `fast` and moved out of
`std.builtin` during this pin's lifetime), and at least one master breakage is not ours at
all — cross-building `-Dos=windows` under master has ICEd the compiler itself
(`Invalid bitcast`, no source location). That is why the lane is non-blocking; do not
chase it.

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

## Do not outline a cold body to shrink a hot frame

A frame is allocated by one `sub $N,%rsp`. The immediate is free, so a 744-byte frame and
a 24-byte one cost the caller the same instruction — and a cold body inlined into a hot
one is charged only where it is *executed*, not where its stack slots sit. Outlining it
therefore buys nothing here and pays three call/ret pairs plus the argument setup and the
post-call reloads for it.

Measured, refuted, do not retry without new evidence. `movepick.nextMove` is entered
1.27M times on `bench 16 1 8`; the three `*_init` stage setups in it run once per picker
and inline a 256-entry move buffer each. Lifting all three into `noinline` helpers did
exactly what it was meant to — `nextMove`'s frame fell from `sub $0x2e8` to `sub $0x18` —
and retired **more** instructions on both tiers:

| tier | before | after | delta |
|---|---|---|---|
| x86-64-sse41-popcnt | 2,756,228,595 | 2,756,803,577 | +0.0209% |
| x86-64-avx2 | 2,188,826,932 | 2,189,157,170 | +0.0151% |

Same sign on both tiers, 24–33x the 0.00063% run-to-run spread, so it is the change and
not the instrument. LLVM had already merged the three buffers into ONE frame, and the
prologue it emits is eight instructions of which exactly one is the allocation.

This is where the port stops being a port. ../rfish took the same change and measured
−0.81%/−0.50% on the same two tiers, because a Rust prologue there was 30 instructions —
the cost it removed does not exist in this tree. **A perf change ported from a sibling is
a hypothesis about THIS compiler's output; disassemble the prologue before believing the
mechanism transferred, and re-measure before believing the win did.**

## Treat `@prefetch` as a cycles-only lever, and hint the exact slot

`@prefetch` moves no work: it retires as one instruction and changes no value. So every
deterministic gate here is structurally blind to it — the signature, perft and every eval
golden read identical across a prefetch that hints the **wrong address**, and callgrind
models no prefetcher on either engine. Instructions and nps can only show a correct
prefetch as a small loss, never as a win. Adjudicate one on `perf_counters` cycles at the
tier that runs, or on a fastchess Elo match, and treat any Ir or nps reading of it as the
instrument rather than the change.

Two placement rules, both mirroring upstream's `position.cpp:1006-1010`:

- **Issue it where the address becomes final, not where the consumer sits.** The hints
  live *inside* `doMove` (`move_do.zig`), at the point the child's keys are final —
  between there and the end of the make there is still the checkers scan, `setCheckInfo`
  and the repetition walk to cover. A hint issued after the make returns has none of that
  lead time, which is the whole value of the hint.
- **Hint the slot the consumer indexes, not the row base.** A pawn-history row is 2 KiB,
  32 cache lines, so hinting `&row[0]` lands on the wrong line for every `(pc, to)`
  outside the first; the address to pass is the one the consumer computes, `pc * 64 + to`
  in i16 units (`history.zig`). Only a cache profile can see this wrong — every
  deterministic gate above is blind to it by construction.

The limit, and it binds hard: more prefetching is not better. A faithful port of
upstream's full seven-hint block reproduces its cache-miss improvement, costs 0.5–0.9%
instructions, and reads **−10.1 ±18.2 Elo** over 1000 self-play games — certain cost,
unproven benefit. Each site earns its place on its own measurement.

## Measure differentially, before attributing

`tools/perf_counters.zig` is the local A/B gate over CPU hardware counters, and it
encodes the method: interleave the two builds and take the median of the per-round
paired ratios (not the ratio of the medians — they disagree), pin the run, and assert
the node counts match so the comparison is the same work. It refuses to report when
those preconditions fail, exiting 2 rather than 0 — a refusal that exits clean is one a
caller reads as a measurement.

**Both modes hold the workload on EVERY round, not just the first.** Round 1 agreeing does
not make round 7 agree: an engine that dies mid-run, a net that goes missing after the first
launch, or an ablation quietly searching a different tree all leave a plausible median the
gate would otherwise compare as though nothing had moved. `first_a`/`first_b` exist for that
check and for nothing else — a round whose count leaves them is named and refused. Point the
A/B path at a script that prints one `Nodes searched` and then a smaller one to see it fire.

**A ratio needs a second binary; a budget does not.** `tools/perf_budget.sh` holds this
tree's own retired-instruction count on `bench 16 1 8` to `tools/instr_budget.golden`,
keyed by arch tier. It exists because the bench signature proves the same *node* count and
says nothing about what those nodes cost, so a change can shed no nodes, keep every gate
`zig build parity` runs green, and still run measurably slower — the one regression class
nothing else here can fail on. Instructions are near-deterministic (measured spread 0.00063% over six runs),
which is what makes an absolute budget gateable where a cycle count is not.

The tolerance is 0.05%, about 50x that spread, and it was **not** chosen by feel: the first
value tried was 0.20%, and mutation-testing rejected it — making the per-node `adjustKey50`
call non-inline costs +0.0876% with the node signature still green, so the gate passed the
exact regression it exists to catch. Pick a tolerance against a measured noise floor *and*
a measured regression.

Rows are keyed by the ARCH tier, and `ARCH=native` is refused in both modes: it names a
different tier on every host, so a row filed under that literal string is one the next
machine compares its own, differently-built binary against — an ISA difference that prints
as a regression. `zig build host-arch` resolves native to the concrete tier to pass instead.
The limit: `ARCH` defaults to a pinned tier, so this closes only the hand-set path the usage
block invites. The keys stay honest because `-Darch=<tier>` fixes a `target_features` set in
`build/arch.zig`, so the tier name determines the code emitted; a build whose flags came from
the host CPU instead would need the resolved target-cpu in the key as well.

It is LOCAL-ONLY and not in `zig build parity`: `perf_event_open` is refused in many CI
containers, and the count is toolchain-specific, so a Zig upgrade legitimately moves it.
Re-derive with `tools/perf_budget.sh update` and carry the measurement in the commit body.
A skip exits **127**, never 0, so "could not measure" cannot be read as "did not regress" —
and being local-only it carries the staleness failure mode `docs/10-tooling-ci.md` records
for `tb-cursed`, so run it by hand after a toolchain bump or a perf commit.

**Attribute cost with `tools/perf_fingerprint.py compare`, never by reading a profile
line.** callgrind emits one entry per *(origin-file, function)* pair -- inlined code is
attributed to the file it came from, under the caller's name -- so one logical function
appears as many lines and its true cost is the sum across all of them. C++ is hit harder
than Zig because upstream's work lives in headers. Reading one line per side once turned a
real 0.99x parity into a reported "1.87x, the worst component". The tool sums each group
and reconciles against callgrind's own `PROGRAM TOTALS`, so it fails loudly instead of
printing a plausible lie. `docs/10-tooling-ci.md` has the runnable sequence.

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
- **callgrind's `--branch-sim` is a MODEL, and it does not decide a prediction question
  — the hardware does.** The two instruments disagreed on a real change and the
  simulator was the one that was wrong. `put_piece` as a `comptime` parameter, both arms
  md5-pinned at `x86-64-sse41-popcnt`, node counts identical on every run:

  | | callgrind | hardware counters, 9 interleaved rounds |
  | --- | --- | --- |
  | instructions | 8,811,385,603 → 8,795,907,833 (−0.176%) | 0.998 |
  | branch misses | 32,616,068 → 33,201,896 (**+1.80%**) | **1.004**, miss rate 3.770% vs 3.769% |

  The two instruction figures agree to the third decimal, which is what makes the branch
  row a disagreement rather than two measurements of different things. Reading the
  simulator would have killed a change that removes work on every compiler and tier.
  callgrind models a static two-bit predictor with a fixed table; a modern core's is
  neither, so the model tracks branch **count** well and branch **outcome** badly.
  Instructions, data refs and call counts are what a callgrind run certifies — those are
  counted, not simulated. For a miss claim, use `perf_counters` (its branch-miss axis
  resolves ~0.2%, per the table above); the cache model carries the same caveat, already
  noted below.
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

## Measure a long clock's workload on the warm-game axis, not on `bench`

Every axis above drives `bench`, and `bench` is a **cold** search of a fixed position list
at depth 8 or 13, against a transposition table the previous position barely warmed. A move
at fishtest's 10+0.1 is a different workload in three ways at once: it runs at ply 40 of one
game, on a table every earlier move has written end to end and on the history, pawn and
correction banks those moves populated; it reaches depth 20 to 25; and the tree it searches
is therefore far smaller per ply, because the move ordering it inherits is already good. A
per-node ratio measured in the first regime does not transfer to the second — a change that
only pays once the table is full reads as nothing on every gate listed above.

`tools/ltc_ab.sh` measures the second regime, driving `tools/ltc_replay.py` over a recorded
move list. Both are local-only: one depth-20 replay is tens of millions of nodes per side
per round, and a hosted runner would measure the hypervisor and then time out.

**The node total is the fidelity check, and it is a wider net than the anchor.** The move
list is fixed input, every search is `go depth D`, and `Threads` is 1, so the node count is
a function of the position and the table alone. Two binaries that search the same tree must
report the same total. The anchor visits only its own thirteen positions from a cold table,
which is the blind spot `docs/10-tooling-ci.md` records; this walks one game to depth 20 and
sees a divergence there. A run whose totals differ is **void, not slow** — `ltc_ab.sh` exits
1 and prints no ratio. Verified by mutation: `razorMargin`'s `482` changed to `481` moves
the 20-ply depth-13 total from 390,947 to 398,988 and the run is refused.

**Startup is subtracted per binary.** Two revisions do not pay the same price to map the
binary and read the `.nnue`, and a raw counter total charges that difference to the search.
`ltc_replay.py startup` opens the same session with the move loop removed, so what it
measures is exactly what the replay carries beyond its nodes.

**Which column carries a claim, measured here rather than assumed.** A/A control, byte-
identical binaries (same md5), 60-ply list, depth 13, 3 rounds:

| column | A/A reading | carries a claim? |
| --- | --- | --- |
| retired instructions | **1.00000** | yes |
| retired branches | **1.00000** | yes |
| branch misses | 0.99526 | only above ~0.5% |
| cycles | 0.97919 | no |
| cache misses | 0.94193 | no — widest of the five |

That is the same ordering the `bench`-driven A/A in the table above reports, and it is the
reason a warm-game verdict is quoted on instructions. Print the A/A beside any counter
column that is quoted at all.

**Pin the driver and the engine to different cores.** `perf_counters --wrap` pins the engine
so both sides of a pair see one thermal state, but the replay driver is a separate process:
landing both on core 0 cost the engine half its throughput here, 309 knps against 327, which
leaves the cycle and wall columns describing the contention. The instruction column does not
move either way, which is why it survives a box this script cannot quiet.

**`--cold` is the control that prices the state, not a second workload.** It sends
`ucinewgame` before every move, so everything but the accumulated table and history bank is
identical. The difference between a `--cold` run and a warm one is what a game's own state
is worth, in nodes, at a depth the long clock reaches.

**`ltc_replay.py clock` removes the wall clock from a time-control question.** With
`nodestime` set, `elapsed()` returns nodes and the budget is a bank the engine keeps itself,
so a whole game is a deterministic function of the move list. A faster engine is then simply
a larger `--npmsec`, and the depth it reaches is how much of that speed the time manager let
it keep — a question that otherwise costs an SPRT.

## Treat a sibling's perf commit as a hypothesis about THIS compiler

A ported ratio is not a measurement. Four rules, each with the case that decides it, and all
four are cheaper than the A/B they save.

**Read the sibling's own compiler grid before porting anything.** One lane moving while the
other stays flat is that lane's codegen, not a change. Zig is LLVM, so the clang cell is the
prediction: pinning a sparse-affine input broadcast reads −0.47% under gcc and **−0.0000%**
under clang, and there is nothing here to collect.

**Ask whether the defect is representable here before porting its fix.** A round-toward-zero
correction exists only where the value is signed. `nnue_inference.pieceCount` returns `usize`,
so the eval bucket's `(count - 1) / 4` is already a shift — the same reason a typed accessor
makes a sign-extension in `nnue_hash.hashBytes` unrepresentable. Type the accessor and the
fix has nothing to fix ([09-type-design.md](09-type-design.md)).

**Measure it here even when both trees made the same edit.** Taking the three list-walk stages
out of `movepick.nextMove`'s dispatch is this tree's shape already, and this tree measured it
**flat** — against −1.6% under clang PGO in the sibling. Same edit, same compiler family,
opposite verdicts.

**A narrow relaxed-atomic load costs a second instruction, and the fix is refused here.**
LLVM has no sign-extending-load pattern for an atomic load: the node's result type is `i16`
and the widening cannot fold into it, so an `@atomicLoad` of an `i16` feeding `i32` arithmetic
lowers to `movzwl (mem)` plus a reg-reg `movswl`, where a plain `i16` load gets one
`movswl (mem)`. The cost is per LOAD and the shared banks are read six times per quiet move
scored. It is real here and not a hypothesis -- 59 of that exact pair in the shipped binary,
counted with `objdump -d`.

Naming the widening in inline asm is what removes it, and that is the reason not to: inline
asm is invisible to ThreatSanitizer, so replacing the relaxed atomic on `SharedHistories`
-- one bank per NUMA node, read and written by every worker on it -- would leave `tsan-race`
still green and no longer watching the reads it exists to watch. A gate that stops looking
is worse than the two instructions. Reopen only with something that keeps the load
instrumented.

The neighbouring half of that change needs nothing: `statsUpdate` already loads straight
into `i32`, so there is no narrow local to truncate and re-widen between the load and the
update.

**Measured dead here, and do not retry without new evidence taken on this tree.** Each was
ported in full, gated bit-exact, measured on the warm-game axis at depth 13 over 1,141,939
nodes with identical node totals, and reverted:

| change | Ir | what it was aimed at |
| --- | --- | --- |
| build the psq index lists before the threat lists | **1.00033** | statement order alone; the sibling reads 0.99589 |
| answer the quiet sort's limit test with a masked `vpcmpq` block compare | **1.00079** | one branch per qualifying move instead of per move |
| share the seven distinct threat `comb` planes behind a pointer | **1.00247** | 133 KB of table down to 57 KB |
| hand the accumulator's row loop an already-offset tile base | **0.999** | one `add` per row instead of per tile |

The first is a **null statement swap** — two builders writing disjoint lists, exchanged — and
it costs a few instructions per node in whichever direction the register allocator happens to
land. It bounds attribution rather than measurement: a change this size has not been shown to
cost anything, and a sibling's opposite sign on it is not a result either.

The second and third failed on their own stated mechanism, which is what makes them decided
rather than merely negative. The `vpcmpq` block compare left **retired branches flat**
(1.00002) where the sibling reads 0.983 — the branches it exists to remove were not there to
remove. The shared plane did buy its footprint, and the cache-miss column shows it (0.973),
but the extra load to reach the plane costs more than the miss it saves: keep the plane
INLINE in the per-attacker block, which is what puts `lut1` and the plane behind one scaled
base.

The fourth is the clearest case of a sibling result being a hypothesis about the OTHER
compiler. `tileRow` computes `index * half_dimensions + tile_off` as one expression, so
LLVM already folds the whole thing into a scaled-index addressing mode; pre-adding
`tile_off` to the weight base once per tile only adds the pointer arithmetic back, at
**+3 Ir/node** (5121 -> 5124, native x86-64-avx512icl, paired perf_counters). The sibling
reads clang -0.28% for it because its `apply` added the tile offset INSIDE the row loop,
where there was something to hoist. Read a sibling's diff for what its base looked like
before taking its ratio.

**A reciprocal for a divide buys latency and costs instructions, so the instruction axis
cannot adjudicate it.** Replacing a depth-indexed divide with a magic multiply retires *more*
instructions (+0.06%) while removing half the engine's integer divides. The divider is not
pipelined, so the claim is cycles — and cycles do not resolve below this box's floor. That
makes it a change this tree cannot currently decide, whatever length of instruction run is
put behind it.
