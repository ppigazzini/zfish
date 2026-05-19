# REPORT-1-DISASTER

Date: `2026-05-19`

## Baseline

- recovery baseline: `84388a47` (`port: inline accumulator update loops`)
- rationale: this is the last `refactor` tip before the first upstream-file
  wrapper spillover commit `50e8753d` (`port: inline zig-backed board helpers`)
- damage definition for this report: any first-party upstream Stockfish source
  file under `src/` changed after `84388a47`, plus the paired retained-owner
  deletions in `zig_compat/uci_bridge.cpp` that accompanied those edits

## Upstream Files Changed Wrt `84388a47`

Committed drift in `refactor` after `84388a47`:

- `src/bitboard.cpp`
- `src/bitboard.h`
- `src/movepick.cpp`
- `src/movepick.h`
- `src/position.cpp`
- `src/position.h`
- `src/search.cpp`
- `src/search.h`
- `src/syzygy/tbprobe.cpp`
- `src/syzygy/tbprobe.h`
- `src/timeman.h`

Current worktree drift from the aborted follow-up slice:

- `src/evaluate.cpp`
- `src/evaluate.h`

Paired retained-owner drift:

- `zig_compat/uci_bridge.cpp`
  - `113` deleted lines relative to `84388a47`
  - these deletions moved wrapper ownership into upstream `src/` files, which
    violated the upstream-file boundary

## Restoration Plan

1. Restore every changed upstream file listed above from `84388a47`.
2. Restore `zig_compat/uci_bridge.cpp` from `84388a47` so the temporary wrapper
   ownership returns to a non-upstream compatibility file.
3. Validate with:
   - `/home/usr00/.zig/zig-x86_64-linux-0.16.0/zig build stockfish`
   - `cd src && env STOCKFISH_BIN=../zig-out/bin/stockfish bash ../tests/signature.sh 2336177`
   - `cd src && printf 'uci\nquit\n' | ../zig-out/bin/stockfish | grep -E 'id name Stockfish|uciok'`
4. Resume conversion only by changing Zig-owned or compatibility-owned surfaces:
   - `zig_build/**`
   - `zig_src/**`
   - `zig_compat/**`
   - `build.zig`
   - tests and maintainer docs
5. Do not edit first-party upstream files under `src/` again unless the user
   explicitly approves that boundary change.

## Applied Recovery Status

- status: complete
- restored upstream files to `84388a47`:
   - `src/bitboard.cpp`
   - `src/bitboard.h`
   - `src/evaluate.cpp`
   - `src/evaluate.h`
   - `src/movepick.cpp`
   - `src/movepick.h`
   - `src/position.cpp`
   - `src/position.h`
   - `src/search.cpp`
   - `src/search.h`
   - `src/syzygy/tbprobe.cpp`
   - `src/syzygy/tbprobe.h`
   - `src/timeman.h`
- restored `zig_compat/uci_bridge.cpp` to `84388a47` so the temporary wrapper
   owners live outside the upstream Stockfish tree again
- validation:
   - `/home/usr00/.zig/zig-x86_64-linux-0.16.0/zig build stockfish`
   - `cd src && env STOCKFISH_BIN=../zig-out/bin/stockfish bash ../tests/signature.sh 2336177`
   - `cd src && printf 'uci\nquit\n' | ../zig-out/bin/stockfish | grep -E 'id name Stockfish|uciok'`
- result: `signature OK: 2336177`
- result: `id name Stockfish dev-20260519-7dbc91a4` and `uciok`
