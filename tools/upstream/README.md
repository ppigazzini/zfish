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
# drive the oracle and match its bytes (docs/09-tooling-ci.md, "a golden is a photograph of
# ourselves"). A resync moving the reference is a legitimate reason to regenerate; a red gate
# you want green is not.
zig build parity ; echo $?                          # the red set names what the sync moved
#   READ THE EXIT CODE, not the log. mt-sanity fails with "does not reproduce the golden"
#   and never prints MISMATCH, so grepping for MISMATCH walks straight past it.
zig build output-golden-update eval-trace-update search-parity-update search-modes-update parity-mt-update
#   ...plus whichever of bench-matrix / chess960 / driver-golden / mate / nodestime /
#   tb-search / export-net / uci-options -update the sync actually moved.
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

## Not ported, and why

`UPSTREAM_BASE` says the port is bit-exact at that sha — it does not say every upstream
commit has a Zig counterpart. An upstream commit marked *No functional change* can be
skipped without moving a single node, so the ones deliberately left out are recorded here
rather than rediscovered by the next person to read the log.

**Nothing to port** — the whole diff is behind an ISA zfish has no backend for, or names a
construct zfish does not have:

| commit | why it is a no-op here |
|---|---|
| `43d4d0ef` Optimize RVV affine transforms | entirely inside `#if defined(USE_RVV)`, plus the RVV branch of `nnz_helper.h` and the RVV-only `dpbusd` macro. Its one non-RVV hunk moves `make_cursor` inside an existing `#if defined(VECTOR)` guard. No RVV backend. |
| `8e3b5b13` LSX/LASX NNUE paths | LoongArch SIMD. Its non-LoongArch half is the `UsePairedActivations` → `ScrambledInput` rename that belongs with `453f2207` below. |
| `23cf5d82` Remove Unused Option Constructor | deletes a C++ ctor overload (`Option::Option(const OptionsMap*)`). zfish's option model has no such constructor. |
| `fd3c762f` Improved Linux shared memory | rewrites `shm_linux.h` around `memfd_create` + Unix-socket fd passing. zfish implements no shared memory at all — nothing in `src/` mentions `memfd` or `shm_open` — so there is no counterpart to improve, only a subsystem to write. |

**Deferred, with the analysis done** — real upstream *speedups* that apply to zfish, each
large enough to need its own measured campaign. AGENTS.md requires a perf commit to carry
tool, rounds, ratio and node count; none of these can be honestly landed inside a sync
commit whose evidence is a bench signature. They cost nothing in correctness: all three are
*No functional change*, so the anchor holds without them.

| commit | what it needs | notes |
|---|---|---|
| `db98633b` Avoid recomputing threat/pp accumulation for some king moves | a new `update_accumulator_hybrid` (~375 lines upstream) | Since the threat and psq accumulators merged, any king move forces a full threat/pp recomputation even though those features only change when the king crosses board halves. The hybrid path rebuilds `new = prev − prev_psq + new_psq + threat/pp delta`, taking both psq terms from the Finny table, and applies only above `MIN_PC_COUNT_HYBRID = 15` pieces because below that summing threats from scratch is cheaper. Castling is deliberately excluded upstream. zfish has no equivalent — `grep hybrid src/engine/eval` is empty. |
| `453f2207` AVX-512 paired activations | widen `pair_activations`, add an AVX-512 `sqrClipPair` | zfish already ports the AVX2 paired path (`nnue_parse.pair_activations`, `nnue_inference.sqrClipPair`), gated to plain AVX2. Upstream now splits the flag in two: `USE_PAIR_ACTIVATIONS` = AVX512 **or** AVX2-pair, and `USE_SCRAMBLED_ACTIVATIONS` = AVX2-pair only. The split is load-bearing — AVX-512 narrows with `cvtsepi32_epi16`/`cvtsepi16_epi8`, which are in-order, so the AVX-512 path needs the paired kernel but **not** the compensating weight scramble the AVX2 `vpackssdw` lane behaviour requires. Getting that backwards silently corrupts fc_1/fc_2 weights. Affects the vnni512 and avx512icl tiers, which is where the tier matrix is weakest. |
| `7b550409` Update NNUE perspectives together | `append_changed_indices_both` on both feature sets + a shared-suffix walk | When both perspectives can update incrementally, catch the lagging one up and then traverse the common suffix once, decoding each transition's changes a single time while keeping per-perspective indices. Upstream keeps its specialised AVX512ICL PP_3Wide generator on the side. Depends on nothing above, but touches the same `evaluate_side` structure `db98633b` does, so doing them together is cheaper than in sequence. |

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
