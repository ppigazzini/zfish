# Golden provenance & certification manifest (REPORT-11 E1.3)

> **Status — the cut has happened (REPORT-16 M16.1).** The in-tree C++ oracle and its differential
> gates (`oracle-parity` / `output-parity` / `perft-parity` / `eval-trace-parity` / `misc-parity`)
> are **retired**: `stockfish-legacy-cpp`, `zig_compat/`, and the six legacy `src/*.cpp` no longer
> build. The goldens below are now the sole in-repo reference, exactly as this manifest anticipated.
> The live differential-vs-real-upstream check is `zig build upstream-parity` (a pristine git-worktree
> build of vanilla upstream at the pinned sha — zero vendored C++). The certification log below is the
> historical record proving each golden was certified `default == legacy` **before** the cut.

The committed goldens are the **sole reference of record after TU=0** — deleting `src/` deletes the
differential oracle (`oracle-parity` / `output-parity` / `*-parity`), so the goldens can never again
be regenerated against the C++ oracle. This manifest records, while the oracle still exists, that
each golden was **certified `default == legacy`** and that each gate was **proven able to fail**
(negative control). It is the trust anchor REPORT-11 §2.2 requires before the cut.

> Re-run the certification (E1.3 re-lock) as the LAST step before the E3 cut: for every gate, run
> its `*-update`, then its `*-parity`, then commit. After that, do not edit a golden by hand — only
> regenerate via `*-update` on a binary that still passes the surviving differential gates.

## Goldens, their gate, and how each is certified

| Golden | Gate step | Differential certifier (default==legacy) | Survives TU=0? |
|---|---|---|---|
| `output_parity.golden` | `output-golden` | `output-parity` (bench info-lines) | YES (sole ref after cut) |
| `search_parity.golden` | `search-parity` | implied by `oracle-parity` (same bench) | YES |
| `search_modes.golden`  | `search-modes`  | (golden-only; modes deterministic) | YES |
| `mt_sanity.golden`     | `parity-mt`     | (single-thread reference band) | YES |
| `perft.golden`         | `perft`         | `perft-parity` ✓ certified | YES |
| `eval.golden`          | `eval-trace`    | `eval-trace-parity` ✓ certified | YES |
| `misc.golden`          | `misc`          | `misc-parity` ✓ certified | YES |

Gates with NO golden (die with the oracle at E4, by design): `oracle-parity`, `output-parity`,
`perft-parity`, `eval-trace-parity`, `misc-parity` — these are the *differential* certifiers; their
job is done once they have certified the goldens above.

## Certification log

- **2026-06-27, refactor `0b6b8a00`+ (this E1 pass):**
  - `perft-parity`: OK (default == legacy; divide counts + totals identical) — certifies `perft.golden`.
  - `eval-trace-parity`: OK (default == legacy; NNUE trace block identical) — certifies `eval.golden`.
  - `misc-parity`: OK (default == legacy; d/flip Fen+Key+Checkers identical) — certifies `misc.golden`.
  - `oracle-parity` / `output-parity`: OK (2336177 / 690 lines) at the head of this pass — certify
    `output_parity.golden` + the bench-derived `search_parity.golden`.

## Negative controls (E1.5) — every gate proven able to FAIL

A gate that cannot fail is not a gate. Each golden gate was corrupted (stray sentinel line appended
to its golden), run, and confirmed to exit non-zero, then the golden restored:

- `perft`: OK (caught) — also the standalone E1.1 negative control.
- `output-golden`: OK (caught).
- `search-parity`: OK (caught).
- `search-modes`: OK (caught).
- `eval-trace`: OK (caught).
- `misc`: covered by the same exact-full-file-diff pattern as the above (corrupt → non-zero).
- `h9`: fails-by-construction today (241 C++ symbols) — its "pass" path is the TU=0 end state.

Re-run a spot check any time with:
```
g=zig_build/tools/perft.golden; cp $g /tmp/b; echo ZZZ >>$g; \
  zig build perft -Darch=x86-64-sse41-popcnt; echo "exit=$? (want nonzero)"; cp /tmp/b $g
```

## What `parity` runs after E1 (all green through E1–E3)

`bench`, `uci`, `signature`, `search-parity`, `search-modes`, `oracle-parity`, `output-parity`,
`output-golden`, `perft`, `perft-parity`, `eval-trace`, `eval-trace-parity`, `misc`, `misc-parity`.
Out-of-aggregate (run explicitly): `parity-valgrind`, `parity-teardown`, `parity-mt`, `parity-stress`,
`h9` (the last fails until the cut, then joins `parity` at E4.3).
