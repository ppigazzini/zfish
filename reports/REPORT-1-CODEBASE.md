# REPORT-1-CODEBASE

Date: `2026-05-19`
Baseline: `89a59d0a` (`port: split bridge position format helpers`)

## Executive Summary

zfish has already crossed the line from a Zig-orchestrated wrapper build into a
Zig-owned build graph and Zig-owned runtime shell for Linux `x86_64`.

The current `build.zig` no longer compiles any imported upstream `.cpp`
translation units directly through `stockfish_sources`; that list is empty.
Instead, the live build compiles:

- `zig_src/main.zig` as the entrypoint
- `19` Zig modules under `zig_build/`
- `2` retained C++ compatibility translation units under `zig_compat/`

That means the remaining porting risk is concentrated rather than spread across
the imported upstream tree. The port is now structurally close to completion,
but it is not functionally complete yet because the two retained C++ bridge
translation units still own first-party runtime behavior.

## Live Validation Snapshot

Validated from the current worktree on `2026-05-19`:

- `/home/usr00/.zig/zig-x86_64-linux-0.16.0/zig build stockfish`
- `cd src && env STOCKFISH_BIN=../zig-out/bin/stockfish bash ../tests/signature.sh 2336177`
- `cd src && printf 'uci\nquit\n' | ../zig-out/bin/stockfish | grep -E 'id name Stockfish|uciok'`

Observed results:

- build succeeded
- `signature OK: 2336177`
- `id name Stockfish dev-20260519-89a59d0a`
- `uciok`

## Status Quo

### 1. Build And Ownership Boundary

- `build.zig` is the active local control plane for the owned Linux `x86_64`
  runtime path.
- `zig_src/main.zig` owns process startup, allocator exports, and the public
  Zig-to-C ABI surface for the current runtime.
- `zig_build/` already contains owned Zig modules across the main runtime
  domains:
  - `bench/`
  - `board/`
  - `eval/`
  - `support/`
  - `time/`
  - `uci/`
- Imported upstream files under `src/`, `tests/`, and `scripts/` are now acting
  primarily as behavioral oracle, headers/data input, and parity harness rather
  than as the compiled engine body for the Zig path.

### 2. What Is Still Retained In C++

The remaining first-party runtime ownership is concentrated in two files:

1. `zig_compat/uci_bridge.cpp`
   - `2558` lines in the current worktree
   - already decomposed into `28` local include slices under
     `zig_compat/uci_bridge/`
   - still owns real runtime behavior, not just ABI glue
   - the retained logic includes the UCI shell/control path, position formatting
     helpers, move parsing helpers, and other engine-facing orchestration

2. `zig_compat/nnue_accumulator_bridge.cpp`
   - `875` lines in the current worktree
   - still owns accumulator stack manipulation, refresh/incremental update
     dispatch, and related NNUE bridge behavior

This is the key reality of the codebase: compilation ownership has moved to
Zig, but logic ownership is not fully Zig-owned until these retained bridges are
eliminated or reduced to trivial ABI shims.

### 3. Upstream Dependency Shape

The project is no longer dependent on compiling upstream runtime translation
units in the Zig build, but it still depends on upstream assets and definitions
for:

- header types and constants consumed by retained C++ bridge code
- test and parity scripts under `tests/`
- helper scripts such as `scripts/net.sh`
- engine data files in `src/`

This is acceptable for the current milestone, but it is not the end state. The
contract in `__DEV/00-CONTRACT.md` is explicit that the destination is a fully
independent Zig runtime with no first-party upstream C++ runtime dependency.

### 4. Documentation Drift

`__DEV/2-MILESTONES.md` still describes `M3` as “6 of the current 24
translation units” rewritten. That was accurate for an earlier phase, but it is
behind live code now.

The live build graph shows a later reality:

- the Zig path compiles no upstream `.cpp` translation units directly
- the remaining retained runtime is concentrated in two compatibility files
- the real open problem is not broad file-count coverage anymore; it is removal
  of the last concentrated C++ runtime owners

## Porting Gap Analysis

The remaining work is not “port more files” in the abstract. The concrete gaps
are:

1. Remove retained runtime logic from `zig_compat/uci_bridge.cpp`
   - The file is already split into smaller include slices, which makes it more
     reviewable, but most of that code still executes in C++.

2. Port the NNUE accumulator bridge to Zig
   - `zig_compat/nnue_accumulator_bridge.cpp` is still a substantial retained
     logic owner and is the highest-leverage remaining C++ surface after the UCI
     bridge.

3. Replace C++-only runtime assumptions with Zig-owned data/layout control
   - The final state cannot depend on first-party C++ types being the runtime
     source of truth.

4. Make `zig build` the default zfish workflow rather than an alternate path
   - The code is ahead of the developer workflow story; the repo still treats
     upstream `src/Makefile` as a normal control path rather than purely as an
     oracle.

## Recommended Completion Plan

### Phase A: Finish Turning `zig_compat/uci_bridge.cpp` Into Thin Glue

Goal:
move all remaining behavior in the UCI bridge into Zig-owned modules, leaving at
most a narrow ABI adapter.

Recommended slice order:

1. Port the command-loop and orchestration methods now still owned by
   `UCIEngine` in C++.
2. Port bench, benchmark, perft, move parsing, and option plumbing into
   `zig_build/uci/`.
3. Move string formatting and protocol-output helpers into Zig and reduce the
   bridge to marshaling only.
4. Delete local include slices as soon as the corresponding Zig owner exists.

Exit condition:

- `zig_compat/uci_bridge.cpp` is either deleted or reduced to trivial wrapper
  code with no material engine logic.

### Phase B: Port `zig_compat/nnue_accumulator_bridge.cpp`

Goal:
move accumulator state ownership, refresh logic, and incremental update logic
into Zig.

Recommended slice order:

1. Split the current file into smaller owned include slices, mirroring the same
   isolation strategy used successfully for `uci_bridge.cpp`.
2. Port `AccumulatorStack` shape, reset/push/pop behavior, and dirty-state
   packing into Zig.
3. Port refresh paths first.
4. Port incremental update paths second.
5. Keep parity checks explicit around eval and search-facing behavior after each
   slice.

Why this order:

- it localizes the highest-risk retained core before reopening broad engine-core
  migration work
- it turns the current large C++ file into a set of independently reviewable
  Zig replacement targets

Exit condition:

- `zig_compat/nnue_accumulator_bridge.cpp` is deleted or reduced to trivial ABI
  glue with no algorithmic ownership

### Phase C: Remove Remaining First-Party C++ Runtime Ownership

Goal:
ensure no first-party runtime behavior is still implemented in imported or
compatibility C++.

Concrete checkpoints:

- no nontrivial engine logic remains in `zig_compat/*.cpp`
- Zig-owned modules define the runtime control flow and core data manipulation
- upstream `src/` is an oracle/input surface only

### Phase D: Finish Workflow Ownership

Goal:
make the codebase operationally Zig-first, not just implementation-first.

Concrete work:

- make local docs default to `zig build`
- keep `src/Makefile` only for comparison and regression triage
- preserve parity gates for `bench`, `uci`, and signature checks from the Zig
  artifact

## Immediate Next Slices

If the project continues from the current state, the highest-value next work is:

1. decompose `zig_compat/nnue_accumulator_bridge.cpp` into small include-owned
   slices so the remaining C++ ownership is explicit and bounded
2. port accumulator stack state and refresh behavior into `zig_build/eval/`
3. port the remaining `UCIEngine` orchestration methods into `zig_build/uci/`
4. refresh `__DEV/2-MILESTONES.md` so it reflects the live architecture instead
   of the older “6 of 24 translation units” snapshot

## Git Hygiene Status

Current repo-local artifact and temp directories in the worktree are:

- `/.zig-cache/`
- `/zig-out/`
- nested temp data under `/.zig-cache/tmp/`

The ignore file should cover those roots explicitly. A reachable-history scan
for the repo's own build-artifact candidates found no committed temporary build
artifact path under the current history for:

- `/.zig-cache/`
- `/zig-out/`
- `/src/temp_builds/`
- `/src/stockfish*`
- `/.build_sha.txt`
- `/.build_date.txt`
- `/tests/bench_tmp.epd`

So the required hygiene action here is to harden `.gitignore`, not to perform a
blind history rewrite with no confirmed target.

## Bottom Line

The port is no longer blocked by broad architectural uncertainty. The structure
is already in place: Zig owns the build, the entrypoint, and most modules. The
remaining task is to remove the last two concentrated C++ runtime owners in a
disciplined, parity-gated sequence.

That means the completion strategy should now optimize for elimination of the
two retained bridge files rather than for another round of scattered,
file-count-based progress.
