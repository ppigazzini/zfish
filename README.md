# zfish

**zfish** is a [Zig][zig] port of the [Stockfish][stockfish] chess engine. The
shipped engine is **pure Zig** — the default `zig build` compiles zero C++
translation units — and is **bit-exact** to upstream Stockfish: it reproduces the
identical `bench` node signature (`2067208` at the current upstream sync) on both
Linux x86-64 and Linux aarch64.

zfish is a derivative work of Stockfish and is distributed under the same
**GNU General Public License v3** — see [Terms of use](#terms-of-use).

zfish, like Stockfish, is **not** a graphical interface; use it with any UCI GUI.

## Status

- Owned runtime target: **Linux x86-64** (primary) and **Linux aarch64**, both
  CI-gated to `bench == 2067208`.
- The whole runtime (~22.8k lines of Zig) is Zig-owned. The NNUE hot path is
  portable `@Vector` SIMD, lowered by LLVM to AVX-512/AVX2/SSE on x86 and NEON on
  aarch64 with no per-arch source.
- The repo contains **zero first-party Stockfish C++** — nothing is vendored. The
  differential check against real upstream is the pristine worktree oracle
  (`zig build upstream-parity`), which builds vanilla upstream at the pinned sha in
  a throwaway git worktree.

## Building

Requires **Zig 0.16.0**. There are no external Zig dependencies.

```
zig build                 # build the engine (ReleaseFast) for the host CPU
zig build net             # download the default external NNUE network (~50 MB)
zig build bench           # run bench and print the node signature
```

The binary is written to `zig-out/bin/stockfish`. The build defaults to
`-Darch=native` (resolved via `scripts/get_native_properties.sh`); pass an
explicit tier to pin one, e.g. `-Darch=x86-64-avx2` or `-Darch=armv8-dotprod`.

The NNUE network is an **external** file (not embedded); `zig build net` fetches
the exact network the binary loads.

## Validating

zfish keeps a battery of parity and determinism gates. The essentials:

```
zig build signature -Dsignature-ref=2067208   # bench signature == reference
zig build parity                               # signature + in-repo golden gates
zig build test                                 # Zig unit tests
```

`zig build parity` runs the in-repo golden + signature gates (no oracle build). The
differential check against pristine upstream Stockfish is `zig build upstream-parity`
— a git-worktree build of vanilla upstream at the pinned sha, with zero vendored C++.
Run `zig build --help` for the full set (perft, eval-trace, search modes, time
management, multi-thread sanity).

## Tracking upstream

zfish stays bit-exact to a moving upstream Stockfish. The steady-state tooling
lives in `zig_build/tools/` — `upstream_sync.sh` plus the pristine
`upstream_oracle.sh` reference. Poll drift with:

```
zig_build/tools/upstream_sync.sh --check
```

## Relationship to Stockfish

zfish is an independent Zig reimplementation that follows upstream
[Stockfish][stockfish] and reproduces its exact search and evaluation behavior.
The repo contains no first-party Stockfish C++ at all; parity is verified by building
vanilla upstream in a throwaway git worktree (`zig build upstream-parity`). All chess
strength and the NNUE networks come from the Stockfish project and its
contributors — see [AUTHORS](AUTHORS).

## Terms of use

zfish, like Stockfish, is free software distributed under the **GNU General Public
License version 3** — see [Copying.txt](Copying.txt). Because zfish is a derivative
of Stockfish, any distribution must include the license and the complete
corresponding source used to build the binary. Changes to the source must also be
made available under GPL v3.

The NNUE networks are trained on [data from the Leela Chess Zero project][lc0-data],
made available under the [Open Database License][odbl].

[zig]:        https://ziglang.org
[stockfish]:  https://github.com/official-stockfish/Stockfish
[lc0-data]:   https://storage.lczero.org/files/training_data
[odbl]:       https://opendatacommons.org/licenses/odbl/odbl-10.txt
