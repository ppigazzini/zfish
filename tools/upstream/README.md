# Upstream sync toolkit

Keeps the native Zig port in lock-step with the always-moving upstream Stockfish master. Full rationale,
the phased port history, findings, and the recommendations these tools implement:
[`../../../__DEV/reports/REPORT-13-FETCH-UPSTREAM.md`](../../../__DEV/reports/REPORT-13-FETCH-UPSTREAM.md)
(see §0.5 OUTCOME + Annex A). Per-commit log: [`SYNC-LOG.md`](SYNC-LOG.md).

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
| `upstream_nodes.sh <sha> [depth] [fen...]` | node-count + bestmove localizer: our build vs oracle@`<sha>` at `go depth`. Bisect `<sha>` to find which commit first diverges when several search commits land together. |
| `upstream_net.sh [sha]` | ensures the target commit's `.nnue` (gitignored, per-worktree) is present in every worktree's `src/`. Run after a net bump so the merged `refactor` actually runs. |

## Steady-state workflow
```
tools/upstream_sync.sh                    # fetch + worklist + bench targets (the whole TODO)
# for each WORKLIST commit (NNUE / bench / NET), oldest-first:
git show <sha> -- <owner src files>                 # the diff; router already named the .zig owner
#   ...port into the .zig owner. FORMULA commits: check C++/Zig integer semantics (see below).
zig build signature -Darch=x86-64-sse41-popcnt      # must equal <sha>'s Bench (from upstream_benchmap.sh)
# net bump?  cp the new .nnue + bump default_eval_file_name (engine.zig + network.zig), then upstream_net.sh
# stuck on a multi-commit gap?  upstream_nodes.sh <sha> to localize which position/commit diverges
tools/upstream_parity.sh                  # whole-engine gate; expect OK at HEAD
# then reharden + merge:
zig build output-golden-update eval-trace-update search-parity-update search-modes-update parity-mt-update
zig build signature output-golden eval-trace perft misc parity-mt parity-valgrind parity-teardown  # all OK
cp UPSTREAM_TARGET UPSTREAM_BASE ; git commit ; git merge --ff-only <branch> ; git tag -f synced-upstream-<sha>
```

## The oracle (REPORT-16 M16.1)
- **Pristine** (`upstream_oracle.sh`): vanilla upstream at any sha; the source of truth for `upstream_parity`
  and `upstream_nodes`. This is how we *follow* upstream, and it is now the **only** oracle.
- The former **in-tree legacy** oracle (`stockfish-legacy-cpp`, the `*-parity` gates) is **retired**:
  it shared this fork's ported Zig hot-path, so it was a self-consistency check rather than a true
  vs-upstream check, and it carried the whole vendored-C++ / `zig_compat/` build. The pristine worktree
  oracle is a strict superset (real upstream, drift-proof, cached no-op in steady state), so it replaces it.

## Integer-semantics watch (FORMULA commits — A4)
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
