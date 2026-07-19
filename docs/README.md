# zfish Developer Documentation

## Overview

zfish is a **pure-Zig port of the Stockfish chess engine**. The default `zig build`
compiles zero C++ translation units, and the shipped binary is **bit-exact** to
upstream Stockfish: it reproduces the identical `bench` node signature. zfish is a
UCI engine, not a GUI, and adds no chess features — it reproduces upstream's search
and evaluation behaviour.

The repository holds three things:

- **The engine** — the whole runtime in Zig, split into three zones: `engine/` (the
  chess library: board, search, NNUE evaluation), `platform/` (the OS/HW runtime:
  threads, memory, NUMA, Syzygy), and `shell/` (the process: UCI, options, `main`).
  The NNUE feature transformer is portable `@Vector` SIMD that LLVM lowers per
  target; the affine layers add comptime x86 intrinsic specializations, all
  bit-identical.
- **The tooling** — `build.zig` is a hand-declared module graph, and `tools/` holds
  the pure-Zig gate battery (the bench signature, golden-diff, metamorphic and
  liveness gates), the structural linters, and the upstream-sync tooling. No
  Stockfish C++ is vendored; the differential check against real upstream builds
  vanilla Stockfish in a throwaway git worktree.
- **The CI** — every push to `main` runs the parity battery across Linux x86-64/aarch64,
  Windows, and macOS, plus valgrind, formatting, and a non-blocking Zig-master
  compatibility lane; fuzzing and upstream-drift detection run on a schedule.

## Documents

| Document | Audience | Description |
|---|---|---|
| [00-architecture.md](00-architecture.md) | All contributors | The three zones, the module graph, the composition root and cycle-break hooks, how a search flows |
| [01-engine-board.md](01-engine-board.md) | Engine contributors | Position and state, bitboards and magics, move generation, legality, Zobrist, repetition, FEN |
| [02-engine-search.md](02-engine-search.md) | Engine contributors | Iterative deepening, alpha-beta and qsearch, move ordering, the transposition table and history, time management |
| [03-engine-eval.md](03-engine-eval.md) | Engine contributors | NNUE: the network and its load path, the feature transformer, the incremental accumulator, inference |
| [04-multithreading.md](04-multithreading.md) | Engine and platform contributors | Lazy-SMP: the pool and worker lifecycle, shared vs per-worker state, thread voting, NUMA replication, determinism |
| [05-tablebases.md](05-tablebases.md) | Engine and platform contributors | Syzygy: WDL and DTZ, the registry and probe path, root and in-search probing, the UCI options |
| [06-platform.md](06-platform.md) | Platform contributors | Memory and NUMA, the thread runtime primitives, the clock, the lifecycle hooks |
| [07-shell.md](07-shell.md) | Shell contributors | `main` as the composition root, the UCI surface, the option model, the engine object and session, bench |
| [08-idiomatic-zig.md](08-idiomatic-zig.md) | Hot-path and build contributors | Portable `@Vector` SIMD, comptime ISA dispatch, static allocation, dependency injection, cross-version shims, the measurement discipline |
| [09-tooling-ci.md](09-tooling-ci.md) | All developers | The build targets, the gate battery, the structural linters, upstream tracking, the CI lanes |
| [10-references.md](10-references.md) | All developers | Stockfish, Zig, chess-domain, and design references |
| [11-writing.md](11-writing.md) | Anyone editing these docs | How the set is organised, the writing rules, what `docs-lint` does and does not check |

For building, the bench gate, and the contribution workflow, see the root
[README](../README.md) and [CONTRIBUTING](../CONTRIBUTING.md).

## Quick start

Requires **Zig 0.16.0**; there are no other dependencies.

```bash
zig build          # build the engine (ReleaseFast) -> zig-out/bin/stockfish
zig build net      # download the external NNUE network into resources/
zig build bench    # run bench and print the node signature
zig build parity   # the full in-repo gate battery
```

`zig build --help` lists every step. The NNUE network is an external runtime input,
not embedded in the binary.

## Technology

| Layer | Technology |
|---|---|
| Language | Zig 0.16.0 (a non-blocking CI lane tracks Zig master) |
| Build | `build.zig` — a hand-declared module graph; no external Zig dependencies |
| SIMD | Portable `@Vector`, lowered by LLVM to AVX-512/AVX2/SSE and NEON |
| Targets | Linux, Windows, macOS on x86-64 and aarch64; ISA tiers via `-Darch` |
| Evaluation | NNUE, external network file |
| Endgames | Syzygy tablebases |
| Protocol | UCI |
| C surface | no exported C ABI — no `export fn`, `callconv(.c)`, `extern var`, or `[*c]`; imports only `malloc`/`free`/`exit` from libc |

## Project layout

```
zfish/
|-- build.zig            -- the hand-declared module graph and every build step
|-- build.zig.zon        -- package manifest (no external dependencies)
|-- src/
|   |-- engine/          -- the chess library; imports nothing outside engine/
|   |   |-- board/       -- position, bitboards, movegen, legality, FEN, Zobrist
|   |   |-- search/      -- the search pipeline, move ordering, TT, history, seams
|   |   |-- eval/        -- NNUE: network, feature transformer, accumulator, inference
|   |   `-- state/       -- worker layout, shared state, per-worker histories
|   |-- platform/        -- threads, memory, NUMA, Syzygy, clock; hosts the engine
|   `-- shell/           -- main (composition root), UCI, options, the engine object
|-- tools/               -- the gate harness, structural linters, upstream tooling
|-- docs/                -- this documentation
|-- net/                 -- the fetched NNUE network and Syzygy tablebases (untracked)
|-- .github/workflows/   -- CI: parity matrix, fuzz, upstream drift
`-- Copying.txt, AUTHORS -- GPL v3; Stockfish attribution
```

`src/`, `tools/`, `build.zig`, the `zfish_*` workflows, and the tracked `*.md` are
Everything in the tree is zfish-owned; there are no upstream mirrors to leave alone.
