# Tooling and CI

How zfish is built, gated, and kept in step with upstream. The build is a single
`build.zig` with no external build system; every gate is a `zig build` step, and CI
runs those same steps on every owned target. For the golden rule and the commands to
run before a commit, see [CONTRIBUTING](../CONTRIBUTING.md).

## The build

`build.zig` declares the whole program by hand: each source file that other files
import is a named module, and every import edge is an explicit `addImport`. There is
no globbing and no auto-discovery — the module graph is data in the build script, and
the zones it encodes are described in [00-architecture.md](00-architecture.md). The
build script is also the only place the ISA tier, the target OS, and the
`build_options` feature flags are chosen; the engine reads them at comptime (see
[08-idiomatic-zig.md](08-idiomatic-zig.md)).

Zig 0.16.0 is the required toolchain. No C++ is vendored or compiled.

### Options

| Option | Values | Purpose |
| --- | --- | --- |
| `-Darch=` | a Stockfish ARCH name (`x86-64`, `x86-64-sse41-popcnt`, `x86-64-avx2`, `x86-64-bmi2`, `x86-64-avx512`, `x86-64-vnni512`, `x86-64-avx512icl`, `armv8-dotprod`, `apple-silicon`, …), or `native` (default) | Selects the ISA tier: the CPU feature set and the `USE_*` macros the NNUE kernels dispatch on. In any RECORDED measurement or table, name the resolved tier (`zig build host-arch` prints it), never `native` — "native" moves between machines and has hidden a whole tier before. |
| `-Dos=` | `linux` (default), `windows`, `macos` | Cross-target the owned runtimes. Orthogonal to `-Darch=`: any tier can target any OS. |
| `-Doptimize=` | `Debug`, `ReleaseSafe`, `ReleaseFast` (default), `ReleaseSmall` | Standard Zig modes. `ReleaseSafe` turns on the bounds/overflow/alignment/null checks the safety lanes rely on. |
| `-Dsignature-ref=` | a node count | Override the bench signature the `signature` step asserts. |
| `-Dtest-coverage` | bool | Run the unit tests under `kcov` into `./kcov-out`. Local only. |
| `-Dstub-eval` | bool | Replace the NNUE evaluation with a material count, for spine isolation. **Not bit-exact — the bench node count moves by construction**, so it is never part of a parity run. Drive it via `tools/material_eval.sh`, which stubs the oracle to match. Default off and comptime, so the shipped build is unchanged. |
| `-Dacc-refresh-only` | bool | Refresh the accumulator from the board every evaluation, never incrementally. **Bit-exact** — a refresh and an incremental chain compute the same accumulator, which is the invariant the design rests on — so the node count holds and the two builds are the same work. Prices the incremental architecture; see [03-engine-eval.md](03-engine-eval.md#and-the-architecture-above-them-does-the-delta-beat-a-rebuild). |
| `-Dno-threat-record` | bool | Compile out `do_move`'s dirty-threat recording, to price it. Refuses to compile without `-Dacc-refresh-only`, which is the only path that reads no record. |

`-Darch=native` is resolved in pure Zig by `tools/native_arch.zig`: it takes the host
CPU that Zig's build graph already resolved via cpuid and walks the tier table
strongest-to-weakest, first match wins, mirroring upstream's
`get_native_properties.sh` predicates (including the Zen1/Zen2 exclusion from the
BMI2 tier). It is a pure function of `std.Target.Cpu`, so it is unit-tested against
synthetic feature sets and needs no `/proc/cpuinfo` and no shell. `build.zig` maps the
returned tier name to its feature set and macros.

### Steps

`zig build --help` is authoritative. The main steps:

| Step | What it does |
| --- | --- |
| `install` (default) | Build the engine binary into `zig-out/bin/stockfish`. |
| `stockfish` | Build the Zig-owned Stockfish engine for Linux x86_64 / aarch64. |
| `net` | Download the default NNUE net into `resources/`. |
| `tb` | Download the 3-man Syzygy tablebases into `resources/syzygy/`. |
| `bench` | Run `stockfish bench` from `resources/`, fetching the net first. |
| `uci` | Run a scripted UCI handshake against the built binary. |
| `signature` | Verify the bench signature via the pure-Zig parity harness. |
| `parity` | The full gate battery (see below). |
| `parity-portable` | The OS-independent subset of `parity` — what the Windows and macOS lanes run. |
| `test` | Run the Zig unit tests. |
| `test-graph` | Run the native-graph (cut) unit tests. |
| `engine` | Build + test the engine module graph headless (no platform/shell). |
| `fuzz` | Run all three coverage-guided fuzz targets — the board/eval/search set, the Syzygy file parse, and that parse through a probe. Fine as a smoke; **for `--fuzz`, prefer the per-target steps below**, since one session cannot start more than `cpu_count - 2` of them. |
| `fuzz-board`, `fuzz-tb`, `fuzz-tb-probe` | The same three targets, one artifact each, so `--fuzz` gives each its own single-worker session and no target can be starved of an async slot. |
| `fuzz-report` | Print how many inputs each fuzz artifact has executed. A `--fuzz` session reports no total, so this is how you see the budget you actually got. |
| `upstream-parity` | Assert the Zig bench == pristine upstream at `UPSTREAM_BASE` (git worktree, no vendored C++). |
| `arch-report` | Coupling report (module + file graphs) + DAG / undeclared-SCC tripwires. |
| `hook-lint` | Cycle-break hooks: ratcheted, each declaring a failure mode + class, all registered. |
| `src-free` / `headless` / `loc` / `docs-lint` | The structural gates (see below). |

Every golden gate is a pair: `<gate>` checks the live fingerprint against the
committed golden, `<gate>-update` regenerates that golden from the current binary.

**A golden is not a reference — it is a photograph of ourselves.** Almost every gate here
records zfish's own output, so a golden can pin a *defect* just as faithfully as it pins
correct behaviour, and the gate will then pass *because* the engine is wrong. Three examples
live in this repo's history: the `eval` golden pinned a trace layout that padded every value
12 spaces wider than upstream; `chess960` pinned the same padding; `driver` pinned a MultiPV
tree (`nodes 2184`, `seldepth 8`, `score cp 28`) that upstream does not search.

So there are two legitimate reasons to regenerate, and one forbidden one:

| situation | regenerate? |
|---|---|
| an upstream resync moved the reference | **yes** — that is what a resync is |
| a fidelity fix made our output *more* like upstream's, so the golden is now the stale one | **yes** |
| the gate is red and you want it green | **no** — that is laundering a bug into the reference |

**The test that separates them: drive the upstream oracle and match it.** Never re-bless a
golden from ourselves — that only records the bug more firmly. For the `driver` case above,
upstream emits `nodes 2498`, `seldepth 10`, `score cp 16`; the regenerated golden reproduces
those bytes, which is what makes the regeneration a correction rather than a capitulation.

`tools/upstream_golden_audit.sh` runs that test for you, on every golden at once. Each one
is built from UCI-observable behaviour and `parity_harness` takes the engine as an argument,
so the same builder points at the pristine oracle unchanged — the audit runs each `<gate>`
check with upstream's binary in place of ours and passes only when our committed golden is
what upstream itself produces. Run it after any reharden; `--list` prints the gate set and a
gate name limits the run.

```sh
tools/upstream_golden_audit.sh                    # all of them
tools/upstream_golden_audit.sh tb-search eval     # just these
```

**The audit runs from `resources/`, and running it anywhere else reads as a divergence.**
That directory is where the net lives *and* where `syzygy/` and `syzygy5/` are fetched. Point
the oracle at its own worktree instead and `SyzygyPath value syzygy` resolves to upstream's
*source* directory (`src/syzygy/tbprobe.cpp`), no tablebase loads, and `tb-search` reports
`with-tb == no-tb` on every row — a rig with no tablebases, not a disagreement. Re-bless a
tablebase golden only from an oracle at the same `SyzygyPath`.

**A resync must refresh every golden it moves, including the ones CI cannot run.** The
node-limited legs of `tb-cursed` went stale for exactly one week this way: the SFNNv16
sync (`f2299c47`) refreshed `tb_search.golden` alongside the anchor and left
`tb_cursed.golden` behind, because `tb-cursed` is local-only — it needs 5-man tables CI
never fetches, so nothing went red and nobody was told. A gate outside `parity` has no
alarm; its golden ages silently until someone runs it by hand, and then it looks exactly
like a regression they just caused. So when a sync moves node counts, re-derive the
local-only goldens in the SAME commit, and when one of them is red, establish whether it
was *already* red before assuming your change did it.

Where a gate can pin the *stream* as well as the bytes, it should: `buildUciOptions` asserts
the handshake on stdout **and fails if any handshake line appears on stderr**, because
reading the wrong stream is how a whole broken handshake passed for months.

## The gate battery

`zig build parity` is the per-push aggregate. Almost all of it runs through
`tools/parity_harness.zig`, a pure-Zig harness invoked as
`parity_harness <check> <stockfish-bin> <golden-or-expected> [check|update]` with
`cwd = resources/` so the spawned engine finds the net. The harness drives the real binary
over UCI, captures stdout and stderr separately (CR-stripped, so Windows text mode
matches the LF goldens), extracts a deterministic fingerprint, and diffs it. It
replaces the former bash golden scripts, which is why `parity-portable` runs
identically on Linux, Windows, and macOS: no `sh`, no coreutils, no GNU-vs-BSD `sed`.

The harness file itself is the DISPATCHER — the check name to builder mapping, the golden
read/write/compare, and `net-missing`, the one gate that must run from a cwd the build does
not pin. Every gate body lives in the `tools/parity/` package, which
`tools/parity/main.zig` re-exports, so the root's import list does not move when the package
is reshaped (the shape `build/main.zig` already uses):

| File | Owns |
| --- | --- |
| `tools/parity/run.zig` | spawn the engine and capture both streams, the line helpers that replaced the bash `sed`/`grep`, and `fail`. Imports std alone — the leaves need these and the ROOT imports the leaves, so a helper left in the root would close a cycle. |
| `tools/parity/structured_diff.zig` | parse an `info`/`bestmove` line into a typed record, report WHICH field drifted, print the golden diff. The one unit-testable file here; the rest drive a real engine. |
| `tools/parity/session.zig` | hold one engine as a live process and read to a mark, for every gate that must not truncate its own search. |
| `tools/parity/golden_shell.zig` | the goldens for what the shell prints: bench info lines, driver emits, search modes, FEN refusals, `d`/`flip`, the `uci` option list, `export_net`. |
| `tools/parity/golden_search.zig` | the goldens for what the search and board compute: search fingerprints, perft, the eval trace, nodestime, `go mate N`, Chess960, the bench matrix. |
| `tools/parity/golden_tb.zig` | the Syzygy goldens (see [05-tablebases](05-tablebases.md)). |
| `tools/parity/gate_runtime.zig` | the gates needing real threads and a real clock: `mt-sanity`, `stress`, `time-mgmt`, and `signature`. |
| `tools/parity/gate_state.zig` | the metamorphic gates, which relate two runs instead of pinning a value. |

Nothing in the package decides its own correctness: a builder that returns a different
fingerprint fails its committed golden, so reshaping one is gated by `zig build parity`
rather than by review.

**Read the harness's exit code, not its log.** `0` passed, `1` means the golden moved and
nothing else, `2` means the harness never reached the comparison — a missing binary, an
unreadable golden, a spawn that failed. Keeping `1` for drift alone is why `main` catches
its own errors instead of returning them: Zig's default handler exits 1, which would make
a dead harness indistinguishable from a real regression. The binary is built ReleaseSafe
for the same reason — it decides whether the engine is correct, and it spawns a subprocess
and waits, so a safety check costs nothing it can measure.

The gates fall into kinds:

**Signature** — the whole-engine invariant.

| Gate | What it proves |
| --- | --- |
| `signature` | The bench node count equals the committed reference. The integer-exact eval is arch- and OS-invariant, so this must hold on every tier. |
| `bench` / `uci` | The binary benches and completes a UCI handshake at all. |

**Golden-diff** — a deterministic fingerprint pinned byte-for-byte.

| Gate | What it proves |
| --- | --- |
| `output-golden` | The bench `info` line output is unchanged. |
| `driver-golden` | The search-driver + emit-callback UCI output is unchanged. |
| `search-parity` | Per-position bench search fingerprints are unchanged. |
| `search-modes` | Deterministic non-bench search modes (real completed bestmoves) are unchanged. |
| `perft` | `do_move`/`undo_move`/movegen: perft divide counts + totals. |
| `eval-trace` | The NNUE eval trace block (the `buildNnueTrace` path). |
| `misc` | `d`/`flip`: Fen/Key/Checkers — fen, flip, zobrist, gives_check. |
| `fen-errors` | The FEN-validation diagnostics: which positions the parser REFUSES, and the exact message and exit status each refusal produces. Upstream treats an unusable `position` as fatal, so this pins a terminating path — the complement of `parity-fen-truncated`, which pins what is accepted. |
| `export-net` | The `export_net` (`write_parameters`) serializer fingerprint. |
| `nodestime` | The `nodestime` time-management node budget. |
| `uci-options` | The `uci` option-list handshake. |
| `mate` | `go mate N`: mate distance + move. |
| `chess960` | `UCI_Chess960` search + castling + eval. |
| `bench-matrix` | Non-default bench configs (hash/depth/nodes/perft). Linux-only. |
| `tb-init`, `tb-wdl`, `tb-dtz`, `tb-root`, `tb-search` | The Syzygy load report, WDL/DTZ probes, root DTZ ranking, and the in-search Step-6 node count == the upstream oracle — depth-limited for the tree shape, node-limited for the per-probe time-check counter reset (a depth stop is blind to check-time cadence). Linux-only. |

**Metamorphic** — a property relating two runs, not a fixed value.

| Gate | What it proves |
| --- | --- |
| `parity-reset` | `ucinewgame` and `Clear Hash` restore engine state, and TT reuse is live — the same position searched again after a reset gives the same result. |
| `parity-skill` | Skill Level 20 is deterministic; Skill Level 0 is random and always legal. |
| `parity-repeat-go` | Consecutive `go` with no intervening `position` yields a bestmove each time and a clean exit. Every golden gate re-sends `position`, so none of them covers the setup-state handoff this drives. |
| `parity-mt` | Threads {2,4} land in a score band around the single-thread golden. |
| `parity-fen-truncated` | A FEN missing its trailing fields SETS, filling upstream's defaults, instead of being rejected. The `fen-errors` golden pins what upstream refuses; this pins what it accepts, and the two edges move independently. |
| `parity-flip-chess960` | `flip` keeps the board's own chess960 variant when `UCI_Chess960` is toggled, so the castling-rights encoding cannot be re-read under the wrong convention. |

**Liveness and timing** — the paths a bench never reaches.

| Gate | What it proves |
| --- | --- |
| `parity-stress` | go/stop storms + construct/destroy churn do not hang, race, or crash the thread runtime. |
| `parity-time` | Wall-clock `go movetime` / `wtime` budgets and the clock-scaling invariants hold. |
| `parity-ponder` | `go ponder` → `ponderhit`/`stop` yields a legal bestmove and a clean exit. |
| `parity-valgrind` / `parity-teardown` | Valgrind memcheck across thread counts, and the searchmoves/rootMoves + Worker-clear lifecycle: no definite leak, invalid access, or bad free. Not in `parity` (memcheck is ~20-50x slower); CI runs them in their own job. |
| `tsan-race` | ThreadSanitizer over four concurrency workloads: **zero** data races. Not in `parity` — it needs its own instrumented build (`zig build tsan-race -Dtsan -Dlto=false`). |

### The race gate

The engine races its shared state **by design**: the transposition table, the shared pawn,
correction, and continuation histories, and the per-Worker `nodes`/`tbHits`/`bestMoveChanges`
counters are all read and written by several threads with no lock. Upstream keeps that defined by typing every such field
`RelaxedAtomic<T>`, whose accessors are relaxed load/store. Relaxed is not ordering — it buys
exactly one thing: the compiler may not tear the access, invent it, or rematerialise it later.

A field that should be relaxed and is not is therefore **not** a crash and **not** a wrong node
count. It is undefined behaviour that the current compiler happens to lower the way you intended,
until it does not. No signature, golden or node-count gate can see it, because the bench is
single-threaded and every one of these gates agrees with the oracle while the race is present.

`zig build tsan-race -Dtsan -Dlto=false` is the instrument that does see it. It drives four
workloads chosen to reach different shared state — a deep search with a 1 MB hash and many threads
(TT and history collisions), tablebases with MultiPV (the Syzygy registry and the PV emitter),
`go`/`stop` churn across thread counts (pool lifecycle, and a TT clear racing a live search), and
`ucinewgame` between searches — and requires **zero** reports.

`-Dtsan` forces LTO off, which ThreadSanitizer requires.

Treat a report as a real defect, not as sanitizer noise. Read the two halves: TSan names both the
access and the previous conflicting one, and a race between an *atomic* write and a plain read
means one side was missed. Both sides of a shared field have to be relaxed.

**Structural and diagnostic**.

| Gate | What it proves |
| --- | --- |
| `src-free` | The shipped binary contains zero C++ Stockfish / libc++ symbols. |
| `parity-net-missing` | Starting with no net produces a named diagnostic and a clean non-zero exit — never a signal. |
| `hook-lint`, `arch-report`, `headless`, `loc` | See below. |

## The structural gates

`docs-lint` gates this documentation set against the tree it describes. Docs are accurate
when written and rot where the code moves under them, so it settles the three rot classes a
machine can: every internal link resolves, every path named in prose is in the tree (`src/`,
`tools/`, `docs/`, `build/`, `.github/`, plus a bare `*.yml` read as a CI lane — but not
`.cpp`/`.h`, which name upstream), and any bench signature quoted in docs equals
`build.zig`'s `signature_reference` —
the anchor moves on every bench-moving upstream sync, and a doc quoting a dead one is worse
than a doc omitting it.

**"In the tree" means the index, not your checkout.** A link target and a path claim are both
resolved against `git ls-files`, because `-e` answers a question about one working directory:
a file left behind by a rename passes locally and is dead for every reader. A path
`.gitignore` names is exempt — the repository decided not to carry it, so a doc naming it
documents the tool that writes it. That exemption is a hole with a shape: a dead *ignored*
path is not checked by anything. Outside a git checkout the gate says so on stdout and falls
back to the filesystem.

It does **not** check whether a sentence is true, and cannot: *"numa_context is a
never-dereferenced stub handle"* parsed, linked, and was false for weeks. Only reading the
code finds that. The gate buys the cheap half so review can spend its attention on the
expensive half.

These gate properties the compiler will not: Zig compiles, links, and runs module
cycles, unused import edges, and unregistered hooks alike.

| Tool | Step | Invariant |
| --- | --- | --- |
| `tools/hook_lint.zig` | `hook-lint` | The cycle-break hooks are bounded and classified. |
| `tools/arch_report.zig` | `arch-report` | The module graph is a DAG; every file cycle is declared. |
| `tools/loc_lint.sh` | `loc` | No new god-file. |
| `tools/headless_lint.sh` | `headless` | `engine/` imports only `engine/`. |
| `tools/src_free.sh` | `src-free` | Zero C++ in the shipped binary. |

**`hook_lint.zig`** bounds the mechanism that buys the DAG. Where an import cycle
would exist, a leaf declares a `pub var` function pointer and the composition root
(`main.zig`) registers the implementation at startup. The lint enforces four rules:
the hook count is **ratcheted** (growth is a design decision, not a drive-by); every
hook declares its **failure mode** — `/// failure: loud` (a named panic when
unregistered) or `/// failure: silent — <why that value is correct unregistered>`;
every file declaring hooks states its **class** (`lifecycle` or `service`); and every
hook is **registered** by the shipped composition root before the engine is
reachable. The last rule is what protects the signature: an unwired hook does not
crash, it silently answers, and the engine keeps looking like a working chess engine
while searching a different tree.

**`arch_report.zig`** reports Lakos CCD/ACD/NCCD over both import graphs — the module
graph and the file graph, which disagree — and always labels which graph a number came
from. It **reports**, never gates, on the numbers: zfish compiles as one LLVM module,
so a cycle costs no compile time and importing a C++-calibrated threshold would be
cargo cult. It **gates** on the binary properties: the module graph is acyclic and every
file cycle is declared. (The zone rule — no engine module importing platform or shell
— is `headless_lint.sh`'s.) It parses the
`addImport` call sites, not just the `module_edges` table — the table is data, the
wiring is the graph, and `main.zig` (the composition root the architecture rests on)
is not in the table at all.

**`loc_lint.sh`** counts repo-owned `.zig` files at or above a line threshold and
ratchets: the gate fails if the count exceeds the baseline (a new god-file appeared,
or one grew past the line) and nudges if it drops. **The baseline is 0 — there is no
waived file left to cite.** Both that ever existed became packages rather than
exceptions: `build.zig` → `build/`, and the parity harness → `tools/parity/` (`find`
recurses, so a subdirectory hides nothing from the scan). Splitting a cohesive file
into coupled micro-files is still the anti-pattern; the answer that worked twice was a
package with a stated layering, not a scatter. When the gate reddens, split at the
**cold seam**:
parsers, table builders and init paths move out; judge a file's length by its cold
lines and leave one long specialized hot body alone. (zfish compiles as one LLVM
module, so a split can never un-inline anything — the seam choice is about
cohesion, not codegen.)

**`headless_lint.sh`** resolves every `@import` in an engine source file to its zone
via `build.zig`'s module table and reports each engine → {platform, shell} up-edge.
It ratchets to zero: at zero, `engine/` compiles, unit-tests, and fuzzes with no
threading runtime, no UCI frontend, and no OS services attached.

**`src_free.sh`** reads the symbol table with `nm`: a C++ translation unit leaves
mangled `Stockfish::…` symbols and the libc++ runtime behind, while the Zig runtime
exports only `zfish_*` and opaque pointers. It refuses to pass a stripped binary
(zero C++ symbols for the wrong reason) and re-asserts the bench signature, so a
src-free binary that lost behavior cannot pass. Linux-only — it needs `nm`.

## The NNUE net and tablebases

The NNUE net is an **external runtime input**, not an embedded blob: the engine loads
it from disk at startup, which is why every harness run sets `cwd = resources/`.

`tools/fetch_net.zig` (`zig build net`) fetches it in pure Zig — no `sh`, no
curl/wget/sha256sum, so it works on every OS. It reads the net name at runtime from
the authoritative Zig constant `default_eval_file_name` in
`src/engine/eval/network.zig`, honoring upstream's name↔contents contract: the file is
named `nn-<first 12 hex of its sha256>.nnue`, so validation recomputes the sha256 and
compares. Sources and order mirror upstream's fetcher. It early-exits when the net is
already present; CI caches it keyed on `network.zig`, so a net bump busts the cache.

`tools/fetch_tb.zig` (`zig build tb`) fetches the 3-man Syzygy set (KPvK KNvK KBvK
KRvK KQvK, WDL + DTZ) into `resources/syzygy/` — the tables the `tb-*` gates probe. It
verifies each file's Syzygy magic header, so a mirror's error page cannot masquerade
as a table. Neither the net nor the tables are committed.

**A unit test that needs the net must name `resources/`, and one that skips without it
skips silently.** `zig build test` runs from the build root, so the net is at
`resources/` — the directory `net_cmd.setCwd(b.path("resources"))` fetches into. The
headless-search tests looked for `net/`, a directory that has never existed, and
`return error.SkipZigTest` is indistinguishable from a pass in the summary line: they
skipped for their entire lifetime, and the suite stayed green the whole time. If you add
a test guarded on a fixture, check the skipped COUNT moved the way you expected — a
fixture-guarded test that never runs is worth less than no test, because it reads as
coverage.

## Tracking upstream

`tools/upstream/` holds the state: `UPSTREAM_BASE` (the sha of the last fully-ported
upstream commit — the fork's history is non-ancestral, so this marker, not
`git merge-base`, defines where the port is), `UPSTREAM_TARGET` (the sha being ported
toward), and `upstream_map.tsv` (the blast-radius manifest mapping `src/` globs to
their Zig owner and a risk tier). `tools/upstream/README.md` is the workflow.

| Script | What it does |
| --- | --- |
| `upstream_sync.sh` | The driver: fetch, compute the behind-count from `UPSTREAM_BASE`, print the worklist + tiered backlog and per-commit bench targets. `--check` prints one terse line for a poll. |
| `upstream_oracle.sh` | Builds **vanilla** upstream at a sha into a detached git worktree and prints the binary path. Its `.zfish_oracle_stamp` carries compiler, ARCH **and sha**, and a disagreement forces `make clean`. The sha belongs there even though `make` tracks mtimes: a checkout that reshapes a header's types relinks stale objects into a binary that builds clean and then core dumps on `bench`. A sync moves the sha once, so the full rebuild costs one build and the steady-state same-sha check stays the incremental no-op it was designed to be. |
| `upstream_parity.sh` | Asserts the native Zig bench == the pristine oracle's bench at the target sha. An empty node count is what a crash, a missing net and a usage error all look like from outside, so it keeps each bench's output and exit status and reports a signal death as such. |
| `upstream_golden_audit.sh` | Re-runs every golden's `<gate>` check with the **pristine oracle** as the engine, proving each committed golden is what upstream itself produces rather than what we produced. See *Goldens* above for the `resources/` cwd requirement. |
| `upstream_transcript.sh` | Diffs the **whole UCI transcript** against the pristine oracle over ~50 command scripts (handshake and option listing, every `NumaPolicy` shape, affinity masks, position setup, the reporters). The bench signature proves the two search the same tree; this proves they print the same bytes. Known divergences are declared by regex so a new one cannot hide behind them. Search is compared at `Threads 1` only — lazy SMP is nondeterministic on both sides. **Two silences are not an agreement**: every way a side can blank (a failed `cd` short-circuiting the `&&`, an engine dying before its banner, `timeout` under load, a `normalise` that eats everything) blanks it to the empty string, and empty compares equal to empty — so the plain equality would score a case that compared nothing as one that agreed. Both-empty is a RIG fault, checked before the fail tally and exiting 2, because a run that compared nothing must not publish the verdict of the cases it did compare; the summary prints the case count as the denominator those tallies are read against. The sibling shipped the live version via an unmatched `*.uci` glob that fed both engines empty stdin (mcfish 01e0b71c). |
| `upstream_router.py`, `upstream_benchmap.sh`, `upstream_nodes.sh`, `upstream_net.sh` | Classify a commit by Zig owner + risk; list per-commit bench checkpoints; localize which position/commit first diverges; place a bumped net in each worktree. |
| `upstream_map_derive.py` | Derive the upstream↔zfish file map from the source comments' upstream citations (zfish ships no C/C++, so every `.cpp`/`.h` citation is upstream); report coverage, uncovered surface, phantom citations, and — `--audit` — rot/drift in the hand-maintained `upstream_map.tsv` (the router's risk model). By-design exclusions carry reasons in `upstream/upstream_map.exceptions`. Adapted from the sibling ports' correspondence-manifest system. |
| `resync_worklist.py` | The pin-advance payoff: diff two upstream SHAs in this repo's own git objects, join every changed file through both maps, rank by churn; flags drift per file and ABSENCE (changed surface with no owner and no exception). Run alongside `upstream_map_derive.py --audit` for the divergence leg. |
| `tools/fuzz_report.zig` | Read the per-artifact execution counters the Zig fuzzer keeps in `<cache>/v` (`std.Build.abi.fuzz.SeenPcsHeader`'s `n_runs`), and gate on them. **`zig build fuzz --fuzz` exits 0 whether it executed half a billion inputs or three**, and prints no total — so a lane that stopped fuzzing reads exactly like one that found nothing, and "found nothing" is only worth publishing if the budget was spent. The sibling port shipped that failure live: its search fuzzer managed three inputs per ninety seconds behind a green lane (mcfish 05914e99). `check` diffs against a pre-run snapshot and requires at least N artifacts to have each cleared a floor — counting the ones that CLEARED, rather than requiring every file to, is what makes it robust to a dirty cache, since `<cache>/v` keeps a file per artifact *build* and old ones sit at zero forever. **Pass it the artifact count, never less** — a quota one short of the number of fuzz roots is one a dark target satisfies for free, so it must move when a root is added. Measured, one 60 s solo session per target: 13.2M / 14.7M / 52.7M inputs, so the nightly floor of 1M each fires on a broken lane, not a slow runner. |
| `src/platform/syzygy/fuzz_targets.zig` | Coverage-guided fuzz of the Syzygy file parse — the only attacker-supplyable **binary** input the engine takes, since a user points `SyzygyPath` at it and every offset the parse advances is read back out of it. Two targets: `setSizes` over arbitrary header bytes, and `decompressPairs` over a table built from fuzzer bytes. Neither asserts a decoded *value* (garbage in, garbage out); they assert that the parse either rejects or leaves every region **inside the buffer it was given**, which is the property the probe path then relies on. It path-imports `decode`/`probe`/`encode` (std-only, no module graph) and rides the same `fuzz` step. It earned its place immediately: the first run found `sizeof_block` and `span` — raw file bytes used directly as shift widths — and the canonical-Huffman recurrence underflowing where upstream's `uint64_t` wraps. |
| `src/platform/syzygy/fuzz_probe.zig` | The same file, fuzzed END TO END: an image is parsed into a registered `TBTable` by `table_load.set`, published by hand so `mapped` never opens anything, and probed through `wdl.probeFen`. That reach is the point — a header the unit targets *accept* can still break an invariant only `doProbeTable` relies on, and no unit-level target can see it. It found exactly that: a pawnful table whose leading piece names the colour with no pawns leaves the leading group empty, and the probe then sorts an inverted range and indexes `lead_pawn_idx` with a square it never wrote (`table_load.set` now refuses it). Fixture-free by construction — a target guarded on tables that are not there SKIPS silently, and a silent skip reads like a clean run. About 4% of purely random images clear the header's length checks and reach the probe, and a plain sweep test asserts that path is still being reached. **`position.initRuntime()` belongs in the test body, not the per-input one** — the slider magics, pawn attacks and Zobrist/cuckoo tables it builds are read-only afterwards, so rebuilding them per input buys nothing and costs three orders of magnitude: 91 inputs/sec against the 220k/sec the same target sustains hoisted, measured as a 60 s solo `zig build fuzz-tb-probe --fuzz`. That is far under the nightly's 1M floor, which is the shape to watch for — a fuzz target doing one-time setup per input is not slow, it is *not fuzzing*. Every fuzz root here hoists it. |
| `uci_fuzz.py` | Bounded, seeded fuzz of the UCI **command loop** — the layer the coverage-guided board targets never reach. Drives a ReleaseSafe build (run it from `resources/`) with pseudo-random streams weighted toward almost-valid input; every stream closes with a verbatim `quit`, so a timeout is a real hang. Clean = exit 0, or either documented exit 1 — the CRITICAL ERROR contract on stdout, and the transposition table's refused-allocation line on stderr, which the generator reaches by asking for Hash's exact max — in range, so it reaches the allocator, but 32TB, so it is refused without a page being touched. Any safety-check panic is a finding. `Hash` and `Threads` are the only options whose value becomes an allocation, so they alone draw from bounded per-option pools and go out unmangled: a truncating mangle rewrites a value the spin parser refuses into one it honours (`Hash value 99999999` → `9999`, a 9.7GB table the box backs and then clears), and that OOM kills the machine and this harness with it, leaving a dead runner and no finding — the failure mode is a lane that dies rather than one that reports. `unbounded_request` enforces the bound on every payload, so a later edit to the pools fails loudly instead of silently. The seed prints first — one flag reproduces a failure. Ported from the sibling port, whose first session caught three real shell bugs. |
| `upstream_walk.py` / `zig build upstream-walk` | Node-for-node diff against the pristine oracle over a **random walk** from the start position, per depth. The sample is generated by the ORACLE, so nothing zfish does can bias which positions are chosen; each position is preceded by `ucinewgame` + `isready` on both engines, because a carried-over TT or history block makes the two sides start from different states and reports divergences that vanish when either position is run alone. Both engines are read to `bestmove` — `go` is asynchronous, and closing stdin early yields a depth-1 stub that reads as a catastrophic divergence. It refuses to run when the two engines loaded different nets, since node counts across different nets are meaningless. Compares the depth *sets*, not their intersection, so an early stop cannot match on a short prefix and still be counted identical. Exits 1 on any divergence and names the shallowest one as the simplest reproducer. Needs the pinned upstream tree and builds the oracle, so it is outside the parity aggregate; `ZFISH_ORACLE_DIR` relocates the oracle worktree. Flags go through `-Dwalk-args="--positions 40 --depth 13"`, **not** a `--` passthrough: `b.args` is a 0.16 field Zig master removed, and the passthrough has no cross-version spelling, where a `-D` option behaves the same on both compilers and appears in `zig build --help`. |
| `zig build upstream-map` | The gate form: declared-map ROT fails outright; two counts are RATCHETED, each from its own file under `tools/upstream/` — the uncovered surface (`upstream_map.baseline`) and the DRIFT, rows whose derived owners the declared rule omits (`upstream_map.drift_baseline`). Lower either as citations land, never raise it. Drift is ratcheted rather than failed so the commit that adds a citation is never the one blocked by it; the row is widened in the same session instead. **Read a drifted row as a blast radius that understates the tree** — `upstream_router.py` decides what a sync must touch from these rows, so an omitted owner is one it routes around silently, and an unratcheted drift count is one nobody counts. The sibling ran three weeks of unread red on the same gate (mcfish a5eeaf1d). Needs the pinned upstream tree's git objects, so it sits outside the parity aggregate; the weekly upstream-check workflow runs it after its drift-detection fetch brings those objects in, and a local clone with the `upstream` remote fetched runs it directly. |

**Fidelity is three probes, not one.** (1) The bench **anchor** proves the fixed
position list. (2) A **position probe** proves positions the anchor never visits, in two
forms: `upstream_nodes.sh` walks a FEN suite you hand it, which localizes a *known*
divergence by bisecting the oracle sha, while `zig build upstream-walk` reaches positions
by playing random legal moves and so probes ground nobody chose — prefer the walk to ask
"is the search faithful", the suite to ask "which commit broke it". (3) A **suite run
under one process** (`bench-matrix` vs the
oracle's totals) proves cross-position *warm-state*: both engines can be
bit-exact on every position in isolation while a persisted counter or TT
interaction drifts across the suite — that exact shape produced a +51-node
drift in mcfish and the conthistDelta overflow here. To bisect a probe-3 drift,
checksum each shared structure per `go` on both engines and diff the streams.

The differential check builds **real upstream** rather than comparing against a
vendored copy: `upstream_oracle.sh` checks the target sha out into a throwaway git
worktree and builds it with upstream's own makefile, so the reference is exactly what
upstream ships at that sha — no C++ lives in this repo, and following upstream is a
one-line checkout rather than a rebase of fork edits. Each binary loads its own net,
so each is benched from its own directory. `upstream-parity` is the whole-engine
convergence gate for a resync; while a resync is in flight its red **is** the
worklist. It runs at sync time, not per push, where per push it would only re-assert
what `signature` already asserts.

## CI

Three workflows in `.github/workflows/`. Every lane pins the ARCH rather than using
`native` — runner CPUs vary, and the gate must be reproducible and CPU-independent.

| Workflow | Trigger | Lanes / what it gates |
| --- | --- | --- |
| `zfish_parity.yml` | push to `main`/`github_ci`, dispatch | `zig fmt --check` over `src/`, `tools/`, `build.zig` — cheap, first, blocks the rest. **Linux x86-64 parity**: `zig build parity`, `test`, `test -Doptimize=ReleaseSafe`, `fuzz` smoke, `parity -Doptimize=ReleaseSafe`, and `tools/arch_determinism.sh` (the same signature on every tier the runner can execute). **Linux aarch64 parity** on a native arm64 runner: the `@Vector` NNUE lowers to NEON with no source changes and must bench identically. **native-os matrix** (Windows x86-64, Windows aarch64, macOS aarch64, macOS x86-64): runs `zig build parity-portable` on the real OS, so the anchor is validated on native hardware. Three of the four build natively; **Windows aarch64 does not** — the native aarch64-windows Zig 0.16.0 segfaults on startup on that runner (a toolchain bug, not ours: the engine cross-compiles to a valid aarch64 PE). That lane runs the x86-64 Zig under Windows-on-ARM x64 emulation and cross-compiles to aarch64-windows; the produced binary still executes natively, so the signature is still proven on arm64 silicon. **Linux valgrind memcheck**: `parity-teardown` + `parity-valgrind`, pinned to the baseline tier. **Zig master compatibility**: non-blocking. |
| `zfish_fuzz.yml` | nightly schedule, dispatch | Two jobs. **Board targets**: `fuzz-board`, `fuzz-tb` and `fuzz-tb-probe` each `--fuzz`ed under `ReleaseSafe` for ~5 min of its own, mutating toward new coverage over FEN-parse → `generateLegal` → make/unmake and over the Syzygy parse; a SIGINT at each sub-budget with no crash passes, a target crash fails early with the safety-check trace and the reproducer. **One session per target, not one over all three** — `Fuzz.start` spawns a worker per artifact via `Io.Group.async`, `Io.Threaded` caps `async_limit` at `cpu_count - 1`, and the coverage task holds a slot, so on the 4-core runner a single session only ever started two of the three and the third left no coverage file at all. The job then asserts the fuzzer **actually executed** — `tools/fuzz_report.zig check` against a pre-run snapshot, all three artifacts, 1M inputs each — because the step above cannot tell an idle lane from a clean one. **UCI command loop**: `tools/uci_fuzz.py` against a `ReleaseSafe` build for ~10 min, seed defaulting to the wall clock so successive nights walk fresh input space; the seed prints first, so a red run names its one-flag reproducer. |
| `zfish_upstream_check.yml` | weekly schedule, dispatch | Three steps. **Drift detection**: fetches `official-stockfish/master` and prints how many commits the port is behind `UPSTREAM_BASE`, into the job summary — always exits 0, and porting stays a deliberate, human-gated session. **Map audit** (`upstream-map`) and **random-walk node parity** (`upstream-walk`) are gates, and both live here rather than in `parity` because they need the pinned upstream tree that a plain checkout of origin does not carry — the detection step's fetch is what brings those objects in. The walk builds the oracle into `runner.temp` and runs a **fixed** seed, so a red weekly run is reproducible from the log with one flag; widen coverage with `--positions`, never with a fresh seed. |

The **Zig master compatibility** lane runs the full Linux parity suite under a
**pinned** Zig master snapshot with `continue-on-error: true`. It is informational:
it reports its real pass/fail in the UI but never fails the workflow, because master
is a moving target that can break through no fault of this repo. The snapshot is
pinned rather than floating so the lane flags this repo's regressions instead of
flapping on upstream's in-flight work, and it is bumped by hand after the port is
verified locally. Its value is early warning on the road to the next toolchain bump.

What the lane does **not** prove is speed. It gates on the node signature, and that
signature is codegen-independent by construction: a toolchain that emits far worse code
still benches 2508687 and still passes green. Measured locally with
`tools/perf_counters.zig`, `0.17.0-dev.1417+20befa4e6` against `0.16.0`, identical tree,
core-pinned: **+16.8%** instructions on sse41, **+23.6%** on avx2, **+10.4%** on avx512,
and **+6117%** on vnni512 — there `nnue_inference.evaluateBucketRaw` loses its vector
lowering and is emulated with scalar `shld`/`shrd` (477 → 5512 instructions), while the
NNUE `vpdpbusd` kernels stay intact. So read the lane as compile-and-correctness only,
and run the counters before believing any toolchain bump.

Two rules the matrix follows. Only lanes that can be reproduced green locally live in
CI — a gate that is red by design, or red for reasons the dev environment cannot
reproduce, stays local (coverage is one: available via `-Dtest-coverage`, absent from
CI). And the Windows aarch64 lane cross-compiles under x64 emulation because the
native aarch64-windows toolchain crashes on that runner; the produced binary still
runs natively, so the harness validates the signature on real arm64 hardware.

## Local-only tooling

`tools/perf_counters.zig` runs interleaved paired A/B measurement over CPU **hardware
counters** via `perf_event_open` directly — the `perf` binary is absent under WSL2 but
the syscall is not, so it works on every tier including AVX-512, where callgrind
SIGILLs. It reports instructions (the work) and cycles/IPC/cache-misses/branch-misses
(the efficiency) at native speed, which neither wall-clock A/B (thermally noisy) nor
callgrind (deterministic instructions, ~50x slowdown) can do together. Read the last
two ratios as a decomposition of the IPC residue: branch misses move for a
**prediction** change, cache misses for a **data** one, neither for code **footprint**. callgrind's
SIGILL is **AVX-512-only**: sse41 AND avx2 profile fine — measure avx2 directly
rather than extrapolating from sse41. `tools/perf_stalls.zig` extends the same
syscall to Zen4 stall-class PMCs (frontend/backend slots, PRF/scheduler/queue
tokens, TLB) for localizing an IPC gap the aggregate counters can only report.

### Spine isolation — measuring the search without the evaluation

`tools/material_eval.sh` builds **both** engines with the NNUE evaluation replaced by a
material count, so a zfish/upstream ratio measures the search spine alone. zfish takes
the stub from `zig build -Dstub-eval` (comptime, default off — the shipped binary is
unchanged and still benches the anchor); the oracle takes
`tools/upstream/material_eval.patch`, which the script applies and reverts on exit,
including on failure. The two stubs are line-for-line equivalents: the same five piece
values, the same side-to-move perspective, and no optimism, complexity blend, rule50
damping or TB clamp on either side.

**Its gate is not the anchor — it is tree equality.** A stubbed build does not bench
2508687 and is not meant to; a different evaluation is a different tree. What must hold
is that the two engines score every position identically, so they search *one* tree and
the ratio is one workload. The script benches both and **refuses to report unless the
node counts match**, because the failure it exists to prevent has already happened once
in this tree: an earlier attempt stubbed the two sides differently, compared two
different workloads, and concluded "the spine, not the NNUE, is the gap" — which was
wrong. A mismatch is never something to compare anyway; it means the stubs disagree.

Both engines still push and pop their accumulator stacks under the stub — only the
forward pass and the blend are skipped — so that bookkeeping stays on both sides of the
ratio rather than being silently removed from one.

It is a **local gate, not CI**: it measures the host it runs on, and a hosted runner's
shared, thermally-uncontrolled CPU cannot carry a performance verdict. The same holds
for the other local scripts (`nps_ab.sh`, `perf_callgrind.sh`,
`perf_fingerprint.py`) and for the local-only `tb-cursed` gate, which needs 5-man
tables that are never fetched in CI. `tb-cursed` pins both the static WDL/DTZ
display and node-limited search totals at the dual `syzygy5:syzygy` path — the
node legs see the per-probe time-check reset on the 5-man/cursed table set that
`tb-search`'s 3-man legs cannot reach, and their golden values are derived from
the oracle under that exact path config (a golden derived at a different
SyzygyPath pins a different probe stream).

### The C backend as a correctness oracle

`tools/c_backend_check.sh` builds the engine through Zig's C backend
(`zig build -Demit-c=true -Dlto=false`), compiles the emitted C back with `zig cc`, and
re-checks the bench anchor. It takes about 80 seconds.

It exists because Zig leaves the in-memory layout of `@Vector` **target-defined**. Code that
depends on a particular representation is correct only by the grace of the backend it was
compiled with — and every other gate here runs through LLVM, so a wrong assumption is
invisible to all of them. The C backend lowers those constructs differently, which makes it
the one cheap way to expose the class from outside.

It has already caught one. The feature transformer built its non-zero-chunk mask with
`@bitCast(@Vector(N, bool))` → `uN`, a movemask that is only correct when bool vectors are
bit-packed. LLVM packs them (`@sizeOf(@Vector(16, bool)) == 2`); the C backend gives one byte
per lane (`sizeof == 16`). Through LLVM the engine benched the anchor and every gate passed.
Through C it benched 3062314, with the startpos eval one centipawn out and every positional
bucket wrong while psqt stayed exact — a wrong number, not a crash, which is why nothing
downstream noticed.

A mismatch here is a divergence between two lowerings of one source, so read it as **our**
bug first — a reliance on something the language does not guarantee — not a backend bug.
`eval` on a fixed position narrows it in one command: psqt correct with positional wrong
points at the transform or the affine.

Two frictions are inherent, not defects. The C backend cannot use LLD, so `-Dlto=false` is
required. And it emits LLVM target intrinsics as extern symbols whose asm name *is* the
intrinsic, which clang cannot select; the script strips that mangling and supplies
`immintrin` implementations, and stops with a named error if it meets one it has no
implementation for.

**It is not a performance path.** The emitted C carries no vector types — the backend renders
`@Vector` as a struct of scalars — so the result runs about 1.9x the instructions of the LLVM
build. Use it to answer "is this correct", never "is this fast".

### Measuring against upstream: the runnable process

Every step below exists because skipping it produced a wrong number. Run them in order;
none is optional.

**Two different oracles. Do not mix them up.**

| oracle | built by | compiler | use it for |
|---|---|---|---|
| **default** | `tools/upstream_oracle.sh --verify` | `COMP=clang COMPCXX=tools/zigcxx` (the script's default) | node counts, `upstream-parity`, **and every instruction/cost ratio and match** — same LLVM backend zfish uses. |
| **gcc study** | `ORACLE_COMP=gcc tools/upstream_oracle.sh` | `COMP=gcc` | studying gcc itself, only. Label any number from it as a gcc build. |

Using a gcc build for a perf ratio measures **gcc vs LLVM**, not zfish vs
Stockfish. It has produced badly wrong conclusions here: against the gcc oracle the
non-NNUE search code read `0.776x` ("zfish is 177M instructions ahead"); on the same
backend it is `1.223x` — zfish is *behind*. The entire claim was gcc's codegen.
Measured on identical source: gcc emits **+7.4% instructions / +7–12% cycles** at
vnni512, so a gcc opponent also flatters zfish in matches.

**Verify provenance at measurement time, before quoting any ratio** — a mislabeled
binary of unknown compiler has faked a standing-table row before (mcfish incident):

```sh
readelf -p .comment zig-out/bin/stockfish <oracle-binary> | grep clang
# both must print the SAME clang version; the oracle script's stamp only covers
# what IT built, not a binary something else left behind.
```

```sh
# 1. Build the reference. --verify is NOT optional: without it the script builds but does
#    NOT check the binary against the commit's own declared `Bench:` line. A stale or
#    locally-edited worktree then benches wrong and every later number is fiction --
#    that has happened here: a leftover eval stub made the oracle bench a value the commit
#    never declared, and the "divergence" it produced was reported as a zfish defect.
#    Defaults: ARCH=x86-64-sse41-popcnt, COMP=clang COMPCXX=tools/zigcxx (stamp-guarded
#    clean on any compiler/ARCH switch). Never hand-run an oracle binary past this script.
bash tools/upstream_oracle.sh --verify             # -> "bench OK (N, matches commit Bench:)"
                                                   #    then prints the binary path

# 2. Build zfish at the SAME ARCH. Comparing a native AVX-512 zfish against the SSE4.1
#    oracle measures the ARCH, not the code.
zig build -Darch=x86-64-sse41-popcnt -p /tmp/zf

# 3. Let the machine idle. NEVER build inside a benchmark command (nps_ab.sh refuses to
#    help you break this); a hot machine has read 934k next to a 2.5M neighbour.

# 4. The headline speed ratio: interleaved, paired, core-pinned, node-count-asserted.
cd net && ../tools/nps_ab.sh /tmp/zf/bin/stockfish <oracle-binary> 12

# 5. Under ~5%? nps CANNOT resolve it (L1). Use callgrind -- deterministic.
cd net && ../tools/perf_callgrind.sh /tmp/zf/bin/stockfish 16 1 8   # OUT=zf.out
cd net && ../tools/perf_callgrind.sh <oracle>/src/sf_sse41  16 1 8   # OUT=up.out
#    ^ the zig-c++ oracle from step 0, NOT the gcc one from step 1.

# 6. Attribute the cost. NEVER read one line per side: callgrind emits one entry per
#    (origin-file, function) pair, so a function's true cost is the SUM over origin
#    files. This tool sums each group and reconciles against callgrind's PROGRAM TOTALS,
#    failing loudly rather than printing a plausible lie.
#    Group on the symbols that EXIST in YOUR build: clang inlines `propagate` into
#    `Network::evaluate`, so a regex written against gcc's symbols matches nothing and
#    the group silently reads 0. Check the names first: perf_fingerprint.py costs up.out
python3 tools/perf_fingerprint.py compare zf.out up.out \
    --group nnue_forward='evaluateBucketRaw|Network::evaluate|propagate|affine' \
    --group accumulator='applyCombined|apply_combined|evaluateSide|evaluate_side' \
    --group movepick='scoreList|nextMove|next_move'

# 7. Subtract startup before quoting a SEARCH ratio. On a shallow bench the net load,
#    magic init and the startup fills (TT clear, history stripes) dominate a d11 run.
```

**Same tree or nothing.** Every comparison above requires both engines to report the
identical node count. A different count is a different workload and the ratio is void;
`nps_ab.sh` asserts this and refuses to run otherwise.

**Call counts, not costs, are the parity test.** `perf_fingerprint.py calls` answers "do
we run Stockfish's algorithm?" -- call counts are inlining-immune, costs are not.
