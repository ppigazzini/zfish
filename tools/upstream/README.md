# Upstream sync toolkit

Keeps the native Zig port in lock-step with the always-moving upstream Stockfish master: detect what
changed upstream, route each changed commit to the Zig file that must absorb it, and gate the result
bit-exact against a pristine upstream build.

**Status:** the port is synced to upstream HEAD (see `UPSTREAM_BASE`). Run `upstream_sync.sh --check`.

## State files
- **`UPSTREAM_BASE`** — sha of the last fully-ported upstream commit. The delta is always `BASE..TARGET`.
  The fork's history is non-ancestral (src/ was copied, not branched), so this marker — not `git
  merge-base` — defines "where we are". Advance it only when the port is bit-exact at a commit.
- **`UPSTREAM_TARGET`** — sha currently porting toward (kept == HEAD once synced).
- **`upstream_map.tsv`** — blast-radius manifest: `src/`-glob → Zig owner → risk tier.

## Tools (in `tools/`)
| script | what it does |
|---|---|
| **`upstream_sync.sh`** | one-command driver: fetch → behind-count → worklist + tiered backlog. `--check` = terse one-line poll (for cron/`/loop`). `--no-fetch` to skip the fetch. **Start here.** |
| `upstream_router.py <ref>` / `--backlog` / `--worklist` | classify a commit/range by Zig files + risk. `--worklist` = only the commits that need action (NNUE-arch + bench-movers + net swaps); the rest are no-ops. Flags `FORMULA` (integer-semantics review) and `NNUE-ARCH`. |
| `upstream_benchmap.sh [base] [target]` | `sha  bench  subject` for the delta, oldest first — the per-commit bit-exact checkpoints. |
| `upstream_oracle.sh [sha] [--verify]` | builds **vanilla** upstream at `sha` into a detached worktree (`/home/usr00/_git/.zfish-upstream-oracle`), prints the binary. The pristine reference — decoupled from the fork's src/ edits. |
| `upstream_parity.sh [our-bin] [sha]` | whole-engine gate: our native bench vs the pristine oracle bench. RED until the resync completes. |
| `upstream_golden_audit.sh [gate...]` | re-runs every golden's `<gate>` check with the ORACLE as the engine, so a reharden is PROVEN rather than self-blessed. `--list` prints the gate set. |
| `upstream_nodes.sh <sha> [depth] [fen...]` | node-count + bestmove localizer: our build vs oracle@`<sha>` at `go depth`. Bisect `<sha>` to find which commit first diverges when several search commits land together. |
| `upstream_net.sh [sha]` | ensures the target commit's `.nnue` (gitignored, per-worktree) is present in every worktree's `src/`. Run after a net bump so the merged `refactor` actually runs. |

## Steady-state workflow
```
# FIRST, before anything else: advance UPSTREAM_TARGET. The router classifies BASE..TARGET,
# so while TARGET still equals BASE it reports "0 of 0 commits need action" no matter how
# far behind the port is -- a clean bill of health that means only that nobody moved the pin.
git fetch upstream master && git rev-parse upstream/master > tools/upstream/UPSTREAM_TARGET

tools/upstream_sync.sh                    # fetch + worklist + bench targets (the whole TODO)
# for each WORKLIST commit (NNUE / bench / NET), oldest-first:
git show <sha> -- <owner src files>                 # the diff; router already named the .zig owner
#   ...port into the .zig owner. FORMULA commits: check C++/Zig integer semantics (see below).
zig build signature -Darch=x86-64-sse41-popcnt      # must equal <sha>'s Bench (from upstream_benchmap.sh)
# net bump?  cp the new .nnue + bump default_eval_file_name (engine.zig + network.zig), then upstream_net.sh
# stuck on a multi-commit gap?  upstream_nodes.sh <sha> to localize which position/commit diverges
tools/upstream_parity.sh                  # whole-engine gate; expect OK at HEAD
# then reharden + merge. Do NOT regenerate blind: `parity` first, and for each RED golden
# drive the oracle and match its bytes (docs/10-tooling-ci.md, "a golden is a photograph of
# ourselves"). A resync moving the reference is a legitimate reason to regenerate; a red gate
# you want green is not.
zig build parity ; echo $?                          # the red set names what the sync moved
#   READ THE EXIT CODE, not the log. mt-sanity fails with "does not reproduce the golden"
#   and never prints MISMATCH, so grepping for MISMATCH walks straight past it.
ZFISH_GOLDEN_UPDATE_FROM_ZFISH=1 zig build output-golden-update eval-trace-update \
    search-parity-update search-modes-update parity-mt-update
#   ...plus whichever of bench-matrix / chess960 / driver-golden / mate / nodestime /
#   tb-search / export-net / uci-options -update the sync actually moved.
#   THE ENV VAR IS REQUIRED and it is not a formality: every -update REFUSES to write a
#   golden photographed from the engine under test. A resync is the one case where the
#   reference genuinely moved -- upstream_parity above has already proven this binary
#   bit-exact against the pristine oracle -- so saying so explicitly is the sanctioned
#   path, and the audit below is what turns "we wrote it" into "upstream agrees".
# LOCAL-ONLY GATES ARE NOT IN parity AND NOT IN CI -- they go stale SILENTLY. Run them by hand
# every sync, or nobody learns their golden aged until it reads as somebody's regression:
zig build tb-cursed                                 # needs the 5-man set in resources/syzygy5
zig build tb-cursed-update                          # only after the oracle agrees, at the SAME SyzygyPath
# THEN PROVE the reharden: every golden re-checked with the ORACLE as the engine. This is the
# mechanical form of "drive the oracle and match its bytes" -- a golden that only agrees with
# ourselves is a photograph of ourselves, bug and all.
tools/upstream_golden_audit.sh                      # expect "N agree, 0 differ"
zig build signature output-golden eval-trace perft misc parity-mt parity-valgrind parity-teardown  # all OK
cp UPSTREAM_TARGET UPSTREAM_BASE ; git commit ; git merge --ff-only <branch> ; git tag -f synced-upstream-<sha>
```

## The oracle
- **Pristine** (`upstream_oracle.sh`): vanilla upstream at any sha; the source of truth for `upstream_parity`
  and `upstream_nodes`. This is how we *follow* upstream, and it is now the **only** oracle.
- The former **in-tree legacy** oracle (`stockfish-legacy-cpp`, the `*-parity` gates) is **retired**:
  it shared this fork's ported Zig hot-path, so it was a self-consistency check rather than a true
  vs-upstream check, and it carried the whole vendored-C++ / `zig_compat/` build. The pristine worktree
  oracle is a strict superset (real upstream, drift-proof, cached no-op in steady state), so it replaces it.

## What each *No functional change* commit did here

`UPSTREAM_BASE` says the port is bit-exact at that sha — it does not say every upstream
commit has a Zig counterpart. A commit marked *No functional change* can be skipped
without moving a single node, which is exactly what makes it easy to skip by accident, so
record what happened to each one rather than leave the next reader to re-derive it from
the log.

**Nothing to port** — the whole diff is behind an ISA zfish has no backend for, or names a
construct zfish does not have:

| commit | why it is a no-op here |
|---|---|
| `43d4d0ef` Optimize RVV affine transforms | entirely inside `#if defined(USE_RVV)`, plus the RVV branch of `nnz_helper.h` and the RVV-only `dpbusd` macro. Its one non-RVV hunk moves `make_cursor` inside an existing `#if defined(VECTOR)` guard. No RVV backend. |
| `8e3b5b13` LSX/LASX NNUE paths | LoongArch SIMD. Its non-LoongArch half is the `UsePairedActivations` → `ScrambledInput` rename that belongs with `453f2207` below. |
| `23cf5d82` Remove Unused Option Constructor | deletes a C++ ctor overload (`Option::Option(const OptionsMap*)`). zfish's option model has no such constructor. |
| `fd3c762f` Improved Linux shared memory | rewrites `shm_linux.h` around `memfd_create` + Unix-socket fd passing. zfish implements no shared memory at all — nothing in `src/` mentions `memfd` or `shm_open` — so there is no counterpart to improve, only a subsystem to write. |
| `d077f9a8` BSD/macOS shared memory, `1ef7f2fe` UniqueFd, `4c37700c` memfd_create check, `762dd1da` SIGPIPE, `9dec2ead` registry simplification | the same missing subsystem as `fd3c762f`: five more commits over `shm_unix.h`/`shm_win.h` and their registry. Nothing here to port until zfish grows shared memory of its own. |
| `3647d524` Remove an incorrect AVX512 comment | deletes a comment about the last affine layer that was already false. zfish's `affineOut1` never carried it. |
| `881e0b45` Class Default Member Initializers for Option | moves `min`/`max`/`idx = 0` out of five C++ constructor initializer lists. zfish's option model has one `OptionsModel.add`, and every caller passes min/max, so there is no initializer list to shorten. |
| `358ab1bc` Cleanup FeatureTransformer Types | names the FT's region sizes and array types so `read_parameters`/`write_parameters` stop restating them. `nnue_dimensions.zig` already declares every count and offset once, and `nnue_parse`/`nnue_ft` read the SAME declarations to write and to read the blob — the property this commit buys, from a stronger direction. |
| `439733ea` Fix rm.exe "Permission denied" on Windows | a Makefile clean rule. zfish builds with `zig build`. |
| `1f711d49` Avoiding Redundant Calculations | hoists `from = to - D` out of `make_promotions`. `movegen.makePromotions` already computes `from` once (movegen.zig). |
| `5062aee5` Place continuation history on large pages | wraps `continuationHistory` in `make_unique_large_page`. `constructSharedHistories` already allocates `cont_data` through `page_alloc` (2 MiB-aligned, `MADV_HUGEPAGE`), same as the correction and pawn arenas. |

**Ported** — the real changes in these ranges. Skipping these silently is how a port
stops being a port:

| commit | what landed |
|---|---|
| `db98633b` | `updateHybrid` (nnue_acc_entry.zig) -- a king move that stays on its half keeps the whole threat/pair accumulation, so only the HalfKA bucket swaps, both buckets coming from the refresh cache. Bounded by `MIN_PC_COUNT_HYBRID = 15`; castling excluded. |
| `7b550409` | `applyCombinedBoth` (nnue_acc_both.zig) -- when neither perspective needs a refresh, catch the lagging one up and walk the common suffix once, decoding each ply's diff a single time. |
| `453f2207` | `sqrClipPair512` (nnue_activations.zig) plus the flag split it introduced -- since superseded by `b52f0147` below, which made every AVX2-or-better tier scramble. |
| `c85637b3` | the quiet futility value loses `39 + 127 * !bestMove` for a flat `164` (search.quietFutilityValue); the dead `no_best_move` parameter goes with it. Bench 2829394. |
| `b0ee1440` | `tileRows`/`psqtRows` (nnue_acc_rowops.zig) -- the sign-and-weight-type-comptime row appliers upstream's three `always_inline` helpers are, with the combined, hybrid and refresh-fused kernels routed through them instead of carrying their own copies of the loop. |
| `b52f0147` | AVX-512 narrows with one `vpackssdw` (`packssdw512`) instead of two `vpmovsdw` + insert, so it now scrambles too: `pairScrambledChunk` holds both maps as one formula over the lane count (four lanes at 512, two at 256), `scrambled_activations == pair_activations`, and AVXVNNI joins the paired kernel. |
| `4150d22b` | `doMoveAcc` prefetches the child's two continuation-correction entries through `history.contCorrIndex`, the same derivation `setContHist` pages with. |
| `de948f0f` | the eval blend drops material from the optimism weight: `(nnue * (91000 + material) + optimism * 7675) / 91000`. Bench 2119477. |
| `fa8b6add` | `search.futilityDepth` -- step 8's cutoff steps 19 down to 13 through a six-threshold LUT as `abs(eval) + abs(beta)` grows, so mating lines stay searched. Bench 2884956. |

**They pay, and that is a separate measurement.** Ablating the hybrid step and the shared
walk together (both routes off, same node count, so one tree with two amounts of work)
costs instructions 1.005 at avx2 and 1.017 at vnni512 -- so the two ports are worth
1.7% of whole-process instructions at the top tier, and more in the search alone.
docs/03-engine-eval.md carries the table. The sibling port measured the same pair
independently at 0.981 against zfish's 0.983.

**A bit-exact bench does NOT prove one of these ran.** Every accumulator route produces
the same values by construction, so a route that never fires is answered correctly by its
fallback and the anchor, the goldens, arch-determinism and the node differential all stay
green. `nnue_acc_update.PathCounts` (compiled in under `builtin.is_test` alone) is what
closes that, and `headless_search.zig` asserts every route moved. Do the same for the next
one: land it, then prove it fires, then mutate it and watch the right gate go red.

## Integer-semantics watch (FORMULA commits)
When porting an arithmetic expression in search/eval, the algorithm is rarely the trap — the **integer
semantics** are. The router flags these `FORMULA`. Check: unsigned promotion (`int * uint64_t` does the
multiply/divide UNSIGNED — differs from signed when a term is negative, e.g. `645b636df`), shift
signedness, `/` truncation direction, and overflow/wrap. Match C++ exactly (`@bitCast`/`*%`/`@truncate`).

## Notes
- The oracle worktree is outside the repo tree (a git worktree of THIS repo at the upstream sha — no extra
  clone). Remove with `git worktree remove --force /home/usr00/_git/.zfish-upstream-oracle`.
- Net files (~90 MB) are gitignored and fetched by `make` into the oracle worktree; copy into each
  worktree's `src/` with `upstream_net.sh`.
- Our `eval`/search info goes to **stderr** and the binary needs `uci`/`isready` before `position`; the
  comparison scripts already handle both. Our `go depth N` needs a trailing pause before `quit` (else it
  returns a depth-1 stub) — `upstream_nodes.sh` sleeps automatically.
