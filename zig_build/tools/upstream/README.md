# Upstream sync toolkit

Keeps the native Zig port in lock-step with the always-moving upstream Stockfish master. Full rationale
and the phased port plan: [`../../../__DEV/reports/REPORT-13-FETCH-UPSTREAM.md`](../../../__DEV/reports/REPORT-13-FETCH-UPSTREAM.md).

## State files
- **`UPSTREAM_BASE`** — sha of the last fully-ported upstream commit. The delta is always `BASE..TARGET`.
  The fork's history is non-ancestral (src/ was copied, not branched), so this marker — not `git
  merge-base` — defines "where we are". Advance it only when the port is bit-exact at a commit.
- **`UPSTREAM_TARGET`** — sha we are currently porting toward (today: `4488343cf`, net
  `nn-af1339a6dea3`, Bench 2102535).
- **`upstream_map.tsv`** — blast-radius manifest: `src/`-glob → Zig owner → risk tier.

## Tools (in `zig_build/tools/`)
| script | what it does |
|---|---|
| `upstream_oracle.sh [sha] [--verify]` | builds **vanilla** upstream at `sha` into a detached worktree (`/home/usr00/_git/.zfish-upstream-oracle`), prints the binary path. `--verify` asserts its bench == the commit's `Bench:` line. The pristine reference — decoupled from the fork's src/ edits. |
| `upstream_benchmap.sh [base] [target]` | `sha  bench  subject` for the delta, oldest first — the per-commit bit-exact checkpoints. |
| `upstream_router.py <ref>` / `--backlog` | classifies a commit/range by Zig files touched + risk; `--backlog` prints the whole delta tiered with bench targets. |
| `upstream_parity.sh [our-bin] [sha]` | whole-engine gate: our native bench vs the pristine oracle bench. RED until the resync completes. |

## Steady-state workflow (REPORT-13 §5.4)
```
git fetch upstream
zig_build/tools/upstream_router.py --backlog        # see the tiered backlog + bench targets
# pick the next commit(s) oldest-first, skipping SKIP-tier (wasm/loongarch/arm/CI):
git show <sha> -- <mapped src files>                # the diff to port
#   ...port into the mapped .zig file(s)...
zig build signature -Darch=x86-64-sse41-popcnt      # must equal <sha>'s bench (post-net-bump)
git commit -m "sync(<sha>): <subject>  [Bench NNNN]"
# when bit-exact at TARGET:
zig_build/tools/upstream_parity.sh                  # expect OK
echo <TARGET-sha> > __DEV/upstream/UPSTREAM_BASE    # advance the marker
```

## Notes
- The oracle worktree (`/home/usr00/_git/.zfish-upstream-oracle`) is outside the repo tree; it is a git
  worktree of THIS repo checked out at the upstream sha, so no extra clone. Remove with
  `git worktree remove --force /home/usr00/_git/.zfish-upstream-oracle`.
- Net files (~90 MB) are fetched by `make` into the oracle worktree; they are not committed.
- Our default build and the oracle load different nets, so `upstream_parity.sh` runs each from its own
  net directory.
