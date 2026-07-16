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

The NNUE hot path — the feature transformer and the affine layers — is written once
in portable `@Vector` code. LLVM lowers it to AVX-512, AVX2, or SSE on x86 and to
NEON on aarch64, with no per-arch source.

```zig
const V = @Vector(16, i16);
const acc: V = a + b; // vpaddw on AVX2, vaddw on NEON — the backend's job
```

The integer-exact eval is arch-invariant, so the one kernel must yield the same
bench on every tier. `zig build parity` runs the signature across tiers to assert
the specializations agree.

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
[ARCHITECTURE](1-architecture.md#the-composition-root-and-the-cycle-break-hooks).
The price is real: a function pointer is an optimizer barrier and its erased
`*anyopaque` context costs type safety, so `zig build hook-lint` bounds the hooks.
Reach for this to invert a *specific* upward dependency, not as a default.

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

A labeled `switch` (computed goto) fits a *data-driven* state machine whose next
state the branch predictor cannot guess. It **pessimizes** a predictable linear one:
when the stages advance in order, the predictor already had them and the computed
goto only defeats it. Leave predictable stage machines as plain control flow.

## Measure differentially, before attributing

To claim a component is the bottleneck, ablate it — stub it out, hold everything
else fixed, measure the delta. To compare two builds, interleave the runs and take
the median; machine temperature and startup jitter otherwise dominate. Control the
confounds first (inlining across a comparison boundary, and comparing the same tree,
not two different ones), and label a hypothesis as a hypothesis. A performance claim
ships with the command that produced it.
