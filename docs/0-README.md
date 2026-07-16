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
  The NNUE hot path is portable `@Vector` SIMD that LLVM lowers per target, so there
  is no per-architecture source.
- **The tooling** — `build.zig` is a hand-declared module graph, and `tools/` holds
  the pure-Zig gate battery (the bench signature, golden-diff, metamorphic and
  liveness gates), the structural linters, and the upstream-sync tooling. No
  Stockfish C++ is vendored; the differential check against real upstream builds
  vanilla Stockfish in a throwaway git worktree.
- **The CI** — every push runs the parity battery across Linux x86-64/aarch64,
  Windows, and macOS, plus valgrind, formatting, and a non-blocking Zig-master
  compatibility lane; fuzzing and upstream-drift detection run on a schedule.

## Documents

| # | Document | Audience | Description |
|---|---|---|---|
| 1 | [1-architecture.md](1-architecture.md) | All contributors | The three zones, the module graph, the composition root and cycle-break hooks, how a search flows |
| 2 | [2-engine-board.md](2-engine-board.md) | Engine contributors | Position and state, bitboards and magics, move generation, legality, Zobrist, repetition, FEN |
| 3 | [3-engine-search.md](3-engine-search.md) | Engine contributors | Iterative deepening, alpha-beta and qsearch, move ordering, the transposition table and history, time management, Lazy-SMP |
| 4 | [4-engine-eval.md](4-engine-eval.md) | Engine contributors | NNUE: the network and its load path, the feature transformer, the incremental accumulator, inference |
| 5 | [5-platform.md](5-platform.md) | Platform contributors | Threads and the pool, memory and NUMA, Syzygy tablebases, the clock, the lifecycle hooks |
| 6 | [6-shell.md](6-shell.md) | Shell contributors | `main` as the composition root, the UCI surface, the option model, the engine object and session, bench |
| 7 | [7-idiomatic-zig.md](7-idiomatic-zig.md) | Hot-path and build contributors | Portable `@Vector` SIMD, comptime ISA dispatch, static allocation, dependency injection, cross-version shims, the measurement discipline |
| 8 | [8-tooling-ci.md](8-tooling-ci.md) | All developers | The build targets, the gate battery, the structural linters, upstream tracking, the CI lanes |
| 9 | [9-references.md](9-references.md) | All developers | Stockfish, Zig, chess-domain, and design references |

For building, the bench gate, and the contribution workflow, see the root
[README](../README.md) and [CONTRIBUTING](../CONTRIBUTING.md).

## Quick start

Requires **Zig 0.16.0**; there are no other dependencies.

```bash
zig build          # build the engine (ReleaseFast) -> zig-out/bin/stockfish
zig build net      # download the external NNUE network into net/
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
| C surface | none — no `export fn`, `callconv(.c)`, `extern var`, or `[*c]` |

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
|-- tests/, scripts/     -- upstream Stockfish mirrors, kept for the rebase path
`-- Copying.txt, AUTHORS -- GPL v3; Stockfish attribution
```

`src/`, `tools/`, `build.zig`, the `zfish_*` workflows, and the tracked `*.md` are
zfish-owned. `tests/` and `scripts/` are upstream mirrors and are not edited here.
