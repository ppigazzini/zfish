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
[ARCHITECTURE](01-architecture.md#the-composition-root-and-the-cycle-break-hooks).
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
printing a plausible lie. `docs/10-tooling-ci.md` has the runnable sequence.

Follow the same discipline by hand: to claim a component is the bottleneck, ablate it
— stub it out, hold everything else fixed, measure the delta. Control the confounds
first (inlining across a comparison boundary; comparing the same search tree rather
than two different ones). Label a hypothesis as a hypothesis. A performance claim
ships with the command that produced it. It is a LOCAL gate — perf counters are not
available in CI, so it never runs there.
