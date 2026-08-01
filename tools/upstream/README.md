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

**Ported** — the three real speedups in this range. Skipping these silently is how a port
stops being a port:

| commit | what landed |
|---|---|
| `db98633b` | `updateHybrid` (nnue_acc_entry.zig) -- a king move that stays on its half keeps the whole threat/pair accumulation, so only the HalfKA bucket swaps, both buckets coming from the refresh cache. Bounded by `MIN_PC_COUNT_HYBRID = 15`; castling excluded. |
| `7b550409` | `applyCombinedBoth` (nnue_acc_both.zig) -- when neither perspective needs a refresh, catch the lagging one up and walk the common suffix once, decoding each ply's diff a single time. |
| `453f2207` | `sqrClipPair512` (nnue_activations.zig) plus the flag split: `pair_activations` (AVX512 **or** AVX2-pair) chooses the kernel, `scrambled_activations` (AVX2-pair alone) drives the weight permutation. Inverting the two silently corrupts the fc_1/fc_2 weights. |

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
