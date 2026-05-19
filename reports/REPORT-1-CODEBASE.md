# REPORT-1-CODEBASE

Date: `2026-05-19`
Baseline: current worktree on top of `b9275148` (`port: collapse retained bridge split follow-up series`)

## Executive Summary

zfish has a Zig-owned build graph for Linux `x86_64`, but it does not yet have
a Zig-owned runtime.

The live `build.zig` compiles:

- `zig_src/main.zig` as the process entrypoint
- `19` Zig modules under `zig_build/`
- `2` retained first-party C++ compatibility translation units under
  `zig_compat/`

The imported upstream `.cpp` translation-unit list in `build.zig` is empty, so
the broad build-graph migration is already done. The remaining problem is
concentrated: the runtime still depends on `zig_compat/uci_bridge.cpp` and
`zig_compat/nnue_accumulator_bridge.cpp`, plus imported upstream bodies that are
textually included into the UCI bridge.

That means the program is no longer in a file-count phase. It is in a boundary-
elimination phase. Future progress must be measured by reduction of live C++
runtime ownership, not by further decomposition of retained C++ into smaller
files.

## Live Validation Snapshot

Validated from the current worktree on `2026-05-19`:

- `/home/usr00/.zig/zig-x86_64-linux-0.16.0/zig build stockfish`
- `cd src && env STOCKFISH_BIN=../zig-out/bin/stockfish bash ../tests/signature.sh 2336177`
- `cd src && printf 'uci\nquit\n' | ../zig-out/bin/stockfish | grep -E 'id name Stockfish|uciok'`

Observed results:

- build succeeded
- `signature OK: 2336177`
- `id name Stockfish dev-20260519-b9275148`
- `uciok`

## Current Architecture

### 1. Build And Workflow Ownership

- `build.zig` is the active owned build graph for Linux `x86_64`.
- `stockfish_sources` is empty, so the Zig build no longer compiles imported
  upstream `.cpp` translation units directly.
- `zig_compat_sources` contains only:
  - `nnue_accumulator_bridge.cpp`
  - `uci_bridge.cpp`
- `build.zig` exposes owned developer steps for `net`, `bench`, `uci`,
  `signature`, and `parity`.
- `NNUE_EMBEDDING_OFF` is still defined in the Zig build, so the default net is
  still an external runtime dependency fetched through `scripts/net.sh`.

### 2. Zig-Owned Surface Already In Place

The current build graph wires `19` Zig modules across the main runtime domains:

- `bench/`
- `board/`
- `eval/`
- `support/`
- `time/`
- `uci/`

This is real structural progress. The project is no longer using Zig only as a
shell around the full upstream build. It already has a substantial Zig runtime
surface and a Zig entrypoint in `zig_src/main.zig`.

### 3. Actual Remaining C++ Runtime Owners

The remaining first-party runtime ownership is still concentrated in two files,
but those two files are not trivial glue.

1. `zig_compat/uci_bridge.cpp`
   - `2449` lines in the current worktree
   - `77` fragment files under `zig_compat/uci_bridge/`
   - still owns substantial runtime behavior
   - textually includes imported upstream bodies from:
     - `../src/position.cpp`
     - `../src/syzygy/tbprobe.cpp`
   - still owns or hosts:
     - UCI engine boot and loop entrypoints
     - network load/save/verify/evaluate/trace behavior
     - tablebase add/update glue
     - position runtime exports and formatting helpers
     - bitboard and move-generation bridge exports
     - logging, formatting, and control-path helpers

2. `zig_compat/nnue_accumulator_bridge.cpp`
   - `311` lines in the current worktree
   - `55` fragment files under `zig_compat/nnue_accumulator_bridge/`
   - still owns performance-sensitive NNUE accumulator behavior through:
     - `zfish_accumulator_incremental_step`
     - `zfish_accumulator_refresh_latest`

The file length is now small because the code has been split into include
fragments, not because the ownership has moved to Zig.

### 4. Live Zig-To-C++ Dependency Map

The current Zig modules still delegate important runtime behavior back into
retained C++.

- `zig_src/main.zig` still boots through retained C++ externs for:
  - engine info text
  - bitboard runtime init
  - position runtime init
  - UCI engine create/loop/destroy
- `zig_build/eval/network.zig` still depends on `8` `zfish_network_*` externs
  for network name access, load/save, piece counting, bucket evaluation, and
  verification.
- `zig_build/eval/nnue_accumulator.zig` still depends on `2`
  `zfish_accumulator_*` externs for incremental and refresh evaluation.

This is the clearest statement of the current gap: the build graph is Zig-led,
but the runtime still crosses into first-party C++ for boot, UCI control,
network evaluation, and NNUE accumulator updates.

### 5. What The Bridge Fragmentation Did And Did Not Achieve

The bridge split work has value, but it has a narrow kind of value.

What it did achieve:

- made the remaining C++ owners easier to inspect
- made review boundaries more local
- exposed the real remaining runtime seams explicitly

What it did not achieve:

- it did not reduce first-party C++ runtime dependence by itself
- it did not remove the `zfish_network_*` or `zfish_accumulator_*` boundaries
- it did not make the runtime materially more Zig-owned

That distinction matters for planning. The next phase should remove boundaries,
not add more fragments.

## Main Gaps And Risks

### 1. NNUE Accumulator Ownership Is Still In C++

`zig_build/eval/nnue_accumulator.zig` already provides the traversal and stack-
walking shell, but the hot-path refresh and incremental update logic still runs
in C++. That is a correctness risk and a performance risk because it keeps one
of the most sensitive engine paths outside Zig ownership.

### 2. NNUE Network Ownership Is Still In C++

`zig_build/eval/network.zig` is a Zig orchestration layer over retained C++
network behavior. Load/save/verify/evaluate/trace are not yet Zig-owned.

### 3. UCI And Engine Control Are Still C++-Owned

`zig_src/main.zig` still creates and drives a retained C++ `UCIEngine`. That
means startup, protocol loop behavior, and some engine-control surfaces are not
yet owned by Zig.

### 4. Imported Upstream Runtime Bodies Are Still Included In A Retained Bridge

`zig_compat/uci_bridge.cpp` still includes upstream `position.cpp` and
`tbprobe.cpp` bodies with skip macros. Even though they are not compiled as
top-level translation units in `build.zig`, they are still part of the runtime
artifact through the retained bridge.

### 5. Milestone Framing Is Behind Live Reality

`__DEV/2-MILESTONES.md` still frames `M3` as “6 of the current 24 translation
units” rewritten. That no longer matches the live architecture.

The current reality is boundary-based:

- direct upstream `.cpp` compilation in the Zig build is already gone
- the remaining first-party runtime risk is concentrated in two retained bridge
  translation units and their extern surfaces

## Work Still To Be Done

The remaining work is not “port more code somewhere in Zig” in the abstract. It
is a specific sequence of ownership transfers.

1. Move the NNUE accumulator refresh and incremental update logic from
   `zig_compat/nnue_accumulator_bridge.cpp` into Zig.
2. Move NNUE network load/save/verify/evaluate/trace behavior from
   `zig_compat/uci_bridge.cpp` into `zig_build/eval/`.
3. Move engine boot, UCI loop, and remaining control-path helpers out of
   `zig_compat/uci_bridge.cpp` and into Zig-owned modules.
4. Replace the imported runtime-body inclusions from `position.cpp` and
   `tbprobe.cpp` with Zig-owned logic or with much narrower non-runtime seams.
5. Update docs, milestones, and workflow defaults so they describe the codebase
   in terms of remaining C++ runtime boundaries rather than old translation-unit
   counts.

## Recommended High-Level Milestone Plan

### M1: Accumulator Ownership Transfer

Goal:
make `zig_build/eval/nnue_accumulator.zig` the real owner of accumulator
refresh and incremental update behavior.

Scope:

- port refresh and incremental logic into Zig
- preserve current data layout and hot-path behavior
- remove the runtime need for:
  - `zfish_accumulator_incremental_step`
  - `zfish_accumulator_refresh_latest`

Exit criteria:

- the accumulator hot path is Zig-owned
- `zig_compat/nnue_accumulator_bridge.cpp` is deleted or reduced to trivial,
  non-algorithmic glue

### M2: Network Ownership Transfer

Goal:
make `zig_build/eval/network.zig` the real owner of NNUE network behavior.

Scope:

- port network load/save/verify/evaluate/trace behavior into Zig
- port parameter read/write helpers into Zig
- remove the runtime need for the current `zfish_network_*` extern surface

Exit criteria:

- `zig_build/eval/network.zig` no longer depends on retained C++ network
  evaluation and serialization helpers
- the network bridge in `zig_compat/uci_bridge.cpp` is deleted or reduced to
  trivial compatibility glue

### M3: UCI And Engine Control Transfer

Goal:
move startup, protocol loop, and remaining engine-control ownership into Zig.

Scope:

- port `UCIEngine`-owned behavior into `zig_build/uci/` and `zig_src/`
- move protocol formatting and command orchestration out of retained C++
- eliminate the boot dependency from `zig_src/main.zig` on retained C++ UCI
  creation and loop control

Exit criteria:

- `zig_src/main.zig` no longer drives a retained C++ UCI engine
- the UCI loop and control plane are Zig-owned on Linux `x86_64`

### M4: Upstream Runtime-Body Eviction

Goal:
remove the remaining imported upstream runtime bodies from the retained bridge.

Scope:

- replace the `position.cpp` inclusion path with Zig-owned runtime logic
- replace the `tbprobe.cpp` inclusion path with Zig-owned logic or a much
  narrower retained seam
- remove any remaining first-party runtime behavior from `zig_compat/*.cpp`

Exit criteria:

- no first-party upstream runtime body is textually included into retained
  bridge code
- `zig_compat/` no longer owns substantive engine behavior

### M5: Zig-First Workflow And Documentation

Goal:
make the codebase operationally Zig-first after the runtime boundary is gone.

Scope:

- update `__DEV/2-MILESTONES.md` to reflect boundary-based progress
- update docs so `zig build` is the default developer workflow
- keep upstream `src/Makefile` as parity oracle and regression reference, not
  as normal zfish control plane

Exit criteria:

- docs and code agree on the live ownership model
- `zig build` is the normal development entrypoint for Linux `x86_64`

### M6: Post-Linux Expansion

Goal:
restore non-Linux and non-`x86_64` targets only after Linux `x86_64` runtime
ownership is fully Zig-owned.

Scope:

- widen targets one by one
- reintroduce CI and packaging claims only after explicit validation

Exit criteria:

- each restored target has explicit ownership, validation, and docs

## Immediate Recommendations

The highest-value next slices are:

1. remove one real accumulator boundary from C++ rather than adding another
   bridge fragment
2. remove one real network boundary from C++ rather than further splitting the
   retained network bridge
3. rewrite `__DEV/2-MILESTONES.md` so the milestone sequence matches the live
   architecture and the new ownership-based completion criteria

## Bottom Line

zfish is past the hard part of build-graph migration and into the harder part
of runtime ownership migration. The current architecture is already narrowed to
two retained first-party C++ runtime owners, which is good news, but those two
owners still sit directly on UCI startup, network behavior, tablebase glue, and
NNUE accumulator updates.

So the right plan from here is not another round of C++ reshaping. The right
plan is a milestone sequence that deletes the remaining C++ runtime boundaries,
starting with the accumulator and network seams and ending with a Zig-owned
UCI/runtime shell for Linux `x86_64`.
