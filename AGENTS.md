# AGENTS.md

zfish is a pure-Zig port of Stockfish. The default `zig build` compiles zero C++ and the
binary is **bit-exact** to upstream: same nodes, same move.

**Read [docs/](docs/README.md) before changing code** — the architecture, each subsystem, the
tooling. [CONTRIBUTING.md](CONTRIBUTING.md) has the workflow. This file is only what an agent
gets wrong before it has read either.

**Docs are part of the change, not after it.** Each zone's page is a live claim about the code
you are touching — [docs/11-writing.md](docs/11-writing.md) maps every page to the source it
owns and marks which run hot. Change hot code, re-read its page and fix it in the SAME commit:
a doc is wrong from the moment the code lands, and every false claim ever found here got there
that way. `zig build docs-lint` catches a dead link, path or anchor; it cannot tell you a
sentence has become false. That part is yours.

## Setup

```sh
zig build                  # binary is `stockfish` (NOT `zfish`), at zig-out/bin/
zig build bench            # fetches the NNUE net into resources/, runs from there
```

The net is a runtime input, not embedded. **Don't** run the binary from the repo root — it
SIGSEGVs on a null net. **Do** run it from `resources/`, or use `zig build bench`.

## The anchor

`bench` prints a node count that must equal `signature_reference` in `build.zig`. **Read it
from build.zig, never from memory or a doc** — it moves on every bench-moving upstream sync.

**A byte-changing edit is not done until a gate says so.**

```sh
zig build parity           # the aggregate — run before calling anything done
zig build signature        # just the anchor
```

Touching anything more than one thread reads or writes — the TT, the shared histories, the
per-Worker counters, the Syzygy registry, the pool lifecycle — also needs the race gate. `parity`
cannot see a data race: bench is single-threaded, so every golden agrees with the oracle while the
race is present.

```sh
zig build tsan-race -Dtsan -Dlto=false   # ThreadSanitizer, must report ZERO races
```

Cross-compile before committing anything under `src/platform/`, `std.Io`, or startup:
`zig build -Dos=windows` and `-Dos=macos`. CI has caught an eager `File.stdout()` here.

**Check the gate's EXIT CODE, never a piped fragment.** `zig build parity | tail`
shows green golden lines while a later gate (loc_lint, docs-lint) is red — this
laundered a red aggregate twice in one session. `zig build parity; echo $?` or
redirect to a log and test `$?`. A gate parity SKIPPED for a missing tool proves
nothing — never report it as a pass.

**Editing a gate, a lane or a tool is its own discipline**, because a broken gate
reports success. Three meta-gates hold it, and each found a real defect on its first
run — twice in the gate being written rather than the code it aimed at:

```sh
tools/negative_control.sh   # can each gate still FAIL? mutate, require red, restore
zig build lane-coverage     # does anything dispatch each step? (in parity)
tools/tools_smoke.sh        # do the tools no lane invokes still run?
```

A gate you add is not done when it passes — it is done when you have **seen it
fail**, by mutation and not by argument. If it makes an allowance (an accepted
divergence, a skip, an excuse), that allowance needs an owner that **expires** it:
a filter outliving its gap silently stops the gate comparing real output.

## Fleets and subagents

Multi-agent perf/refactor fleets are a standing pattern here. Every rule below was
paid for:

- **Never `git stash`** — the stash is repo-wide across worktrees; parallel agents
  racing it corrupt each other. Recover by SHA instead.
- **Charter disjoint FILES, not just disjoint metrics** — two agents once shipped
  the same port of the same upstream function from opposite charters.
- **Unique scratch filenames + md5-pin every measured binary** — a shared scratchpad
  collision (`cand-sse41`) once turned a SIGILL-dead half-run into a fake 20% win.
  Reject any callgrind output missing its `Nodes searched` line.
- **Agents write nothing outside their own worktree** — measurement results and
  ledger rows travel in the final report; the integrator records them.
- **Subagents are not re-woken by their own background jobs** — wait on
  measurements with a foreground `until` loop, or the agent stalls silently.
- **Worktree commits are candidates, not integrations** — the integrator
  cherry-picks onto clean HEAD, re-runs the full gates there, and owns the
  evidence; an agent never touches main.
- **A worktree starts where its branch last was, not at your HEAD** — reset it
  to the intended base and verify with `git log` before building any baseline.

## Performance work

The measurement laws and instrument blind spots are in
[docs/08-idiomatic-zig.md](docs/08-idiomatic-zig.md) — read them before any
perf work. **Read the falsified list before optimizing anything.** Measured
dead here, do not retry without new evidence: prefetch-as-addition, PGO/BOLT,
labeled-switch dispatch, `noalias` on the hot kernels, live-value reshaping
of the search body in either direction (field hoisting AND cold-body
outlining), and outlining `nextMove`'s three stage setups — which shrank its
frame 744 bytes to 24 and retired MORE instructions on both tiers, because a
frame costs one `sub rsp` immediate here whatever its size. Measured the other way, so do not "simplify" it away: the
incremental accumulator is worth 26.1% of whole-process instructions against a
rebuild-per-evaluation design, and `do_move`'s dirty-threat recording that pays
for it costs 1.44% (`-Dacc-refresh-only`, `-Dno-threat-record`;
[docs/03-engine-eval.md](docs/03-engine-eval.md)).

A perf commit that does not carry its measured evidence (tool,
rounds, ratio, node count) in the body is incomplete — the `perf(...)` commit
bodies are the durable ledger a fresh clone gets.

## Traps that cost real time

Pointers, not explanations — each is documented where it belongs.

| trap | where |
|---|---|
| A golden can pin a **defect**: `<gate>-update` on a red gate launders a bug. It now REFUSES; `tools/upstream_golden_audit.sh` is the way through. Do not reach for the override to get past a red gate. | [docs/09-tooling-ci.md](docs/09-tooling-ci.md) |
| A gate you added is not done when it passes — it is done when you have **seen it fail**. Same for a lane: a check nothing dispatches is a claim, not a check. | [docs/09-tooling-ci.md](docs/09-tooling-ci.md) |
| **The oracle is ALWAYS the zig-c++ build** (`tools/upstream_oracle.sh` defaults to it via `tools/zigcxx`) — for ratios AND matches. A `COMP=gcc` build measures **gcc**, not zfish (+7.4% instructions on identical source, measured); reach for it only to study gcc itself, via `ORACLE_COMP=gcc`, and label the result as such. | [docs/09-tooling-ci.md](docs/09-tooling-ci.md) |
| nps cannot resolve <5%; callgrind cost must be summed across origin files. | [docs/08-idiomatic-zig.md](docs/08-idiomatic-zig.md) |
| Serial cycle A/B on this box has a **±1% run-to-run floor and a +0.65% A/A bias** — a sub-1% single-tier cycle claim is unmeasurable; adjudicate with the deterministic instruction axis, or with fastchess Elo (concurrency 4, idle box, `Timeouts:` near zero — a background build forfeits games exactly like SMT oversubscription). | [docs/08-idiomatic-zig.md](docs/08-idiomatic-zig.md) |
| callgrind is **blind to software prefetch** on both engines — no callgrind bar can certify a prefetch change. An instruction win can still be a cycle **loss** (three recurrences); cycles at the tier that runs decide. | [docs/08-idiomatic-zig.md](docs/08-idiomatic-zig.md) |
| loc_lint god-file regression: **split the file**; raising `LOC_BASELINE` is laundering. A bit-exact slice can still redden the aggregate this way. | [docs/09-tooling-ci.md](docs/09-tooling-ci.md) |
| Bit-exactness ≠ faithfulness: the bench is a fixed position list, so a divergence off those positions is invisible to the anchor. Ask "is the search faithful" with `zig build upstream-walk` (random walk, positions nobody chose); ask "which commit broke it" with `tools/upstream_nodes.sh` (a FEN suite you supply, bisected over oracle shas). Neither covers time management, SMP or Syzygy. | [docs/09-tooling-ci.md](docs/09-tooling-ci.md) |
| A perf-symbol group regex is a **hypothesis** (upstream `do_move`'s signature contains `TranspositionTable const*`; inlining differs per side) — verify per-symbol before trusting any component ratio. | [docs/08-idiomatic-zig.md](docs/08-idiomatic-zig.md) |
| `tools/perft.golden` counts are **facts about chess**, not a golden: a mismatch is always a movegen bug, never an update candidate. | [docs/09-tooling-ci.md](docs/09-tooling-ci.md) |
| Run `zig build test -Doptimize=ReleaseSafe` locally — CI runs it, and deep node-limited searches have tripped latent i32 overflows the default build can't see. | [docs/09-tooling-ci.md](docs/09-tooling-ci.md) |
| A warm cache lies: `zig build test` can pass on stale state while CI's arch-pinned fresh compile catches a module-resolution break. Gate refactors with a fresh `-Darch=x86-64-sse41-popcnt` build. | [docs/09-tooling-ci.md](docs/09-tooling-ci.md) |
| `zig fmt --check` is CI's first gate and blocks everything after it; deletions leave blank lines fmt rejects. Run it every commit. | [docs/09-tooling-ci.md](docs/09-tooling-ci.md) |
| A type is free while a value is **carried** and can cost when many are **live at once** in one big function. Type an index space whose swap would not fault; do NOT type a quantity that is computed with — a score, a `Depth` and a ply pushed into the transformer are all refuted, and Zig's lack of operator overloading makes the diff worse than where they were measured. | [docs/08-idiomatic-zig.md](docs/08-idiomatic-zig.md) |
| Comments are **imperative mood**; never pin a number a gate computes. | [docs/11-writing.md](docs/11-writing.md) |
| The shipped binary is ReleaseFast: **no bound, cast, overflow or alignment is checked anywhere**. Code that parses the `.nnue` or a Syzygy file is reading bytes zfish did not write — place `@setRuntimeSafety(true)`, carve slices not `[*]`, and port C's wrapping arithmetic as `+%`/`*|`. Price the placement first: safety over one per-byte loop cost +22.8% of a bench. | [docs/08-idiomatic-zig.md](docs/08-idiomatic-zig.md) |

## Commits

**One logical change per commit** — a commit that touches three modules cannot be
bisected when the node count moves.

Conventional subject ≤72 chars, blank line, body wrapped at 80 carrying the evidence: gate
output and exit code, not "should work". **Don't** `git push` — commit locally and stop unless
asked. **Don't** add co-author or generated-by trailers.
