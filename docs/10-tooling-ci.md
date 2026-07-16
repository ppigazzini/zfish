# Tooling and CI

How zfish is built, gated, and kept in step with upstream. The build is a single
`build.zig` with no external build system; every gate is a `zig build` step, and CI
runs those same steps on every owned target. For the golden rule and the commands to
run before a commit, see [CONTRIBUTING](../CONTRIBUTING.md).

## The build

`build.zig` declares the whole program by hand: each source file that other files
import is a named module, and every import edge is an explicit `addImport`. There is
no globbing and no auto-discovery — the module graph is data in the build script, and
the zones it encodes are described in [1-architecture.md](1-architecture.md). The
build script is also the only place the ISA tier, the target OS, and the
`build_options` feature flags are chosen; the engine reads them at comptime (see
[9-idiomatic-zig.md](9-idiomatic-zig.md)).

Zig 0.16.0 is the required toolchain. No C++ is vendored or compiled.

### Options

| Option | Values | Purpose |
| --- | --- | --- |
| `-Darch=` | a Stockfish ARCH name (`x86-64`, `x86-64-sse41-popcnt`, `x86-64-avx2`, `x86-64-bmi2`, `x86-64-avx512`, `armv8-dotprod`, `apple-silicon`, …), or `native` (default) | Selects the ISA tier: the CPU feature set and the `USE_*` macros the NNUE kernels dispatch on. |
| `-Dos=` | `linux` (default), `windows`, `macos` | Cross-target the owned runtimes. Orthogonal to `-Darch=`: any tier can target any OS. |
| `-Doptimize=` | `Debug`, `ReleaseSafe`, `ReleaseFast` (default), `ReleaseSmall` | Standard Zig modes. `ReleaseSafe` turns on the bounds/overflow/alignment/null checks the safety lanes rely on. |
| `-Dsignature-ref=` | a node count | Override the bench signature the `signature` step asserts. |
| `-Dtest-coverage` | bool | Run the unit tests under `kcov` into `./kcov-out`. Local only. |

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
| `net` | Download the default NNUE net into `net/`. |
| `tb` | Download the 3-man Syzygy tablebases into `net/syzygy/`. |
| `bench` | Run `stockfish bench` from `net/`, fetching the net first. |
| `uci` | Run a scripted UCI handshake against the built binary. |
| `signature` | Verify the bench signature via the pure-Zig parity harness. |
| `parity` | The full gate battery (see below). |
| `parity-portable` | The OS-independent subset of `parity` — what the Windows and macOS lanes run. |
| `test` | Run the Zig unit tests. |
| `test-graph` | Run the native-graph (cut) unit tests. |
| `engine` | Build + test the engine module graph headless (no platform/shell). |
| `fuzz` | Run the coverage-guided fuzz targets (add `--fuzz` to fuzz continuously). |
| `upstream-parity` | Assert the Zig bench == pristine upstream at `UPSTREAM_BASE` (git worktree, no vendored C++). |
| `arch-report` | Coupling report (module + file graphs) + DAG / undeclared-SCC tripwires. |
| `hook-lint` | Cycle-break hooks: ratcheted, each declaring a failure mode + class, all registered. |
| `src-free` / `headless` / `loc` | The structural gates (see below). |

Every golden gate is a pair: `<gate>` checks the live fingerprint against the
committed golden, `<gate>-update` regenerates that golden from the current binary.
Regeneration is a deliberate act — it belongs to an upstream resync, not to a
failing gate.

## The gate battery

`zig build parity` is the per-push aggregate. Almost all of it runs through
`tools/parity_harness.zig`, a pure-Zig harness invoked as
`parity_harness <check> <stockfish-bin> <golden-or-expected> [check|update]` with
`cwd = net/` so the spawned engine finds the net. The harness drives the real binary
over UCI, captures stdout and stderr separately (CR-stripped, so Windows text mode
matches the LF goldens), extracts a deterministic fingerprint, and diffs it. It
replaces the former bash golden scripts, which is why `parity-portable` runs
identically on Linux, Windows, and macOS: no `sh`, no coreutils, no GNU-vs-BSD `sed`.

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
| `export-net` | The `export_net` (`write_parameters`) serializer fingerprint. |
| `nodestime` | The `nodestime` time-management node budget. |
| `uci-options` | The `uci` option-list handshake. |
| `mate` | `go mate N`: mate distance + move. |
| `chess960` | `UCI_Chess960` search + castling + eval. |
| `bench-matrix` | Non-default bench configs (hash/depth/nodes/perft). Linux-only. |
| `tb-init`, `tb-wdl`, `tb-dtz`, `tb-root`, `tb-search` | The Syzygy load report, WDL/DTZ probes, root DTZ ranking, and the in-search Step-6 node count == the upstream oracle. Linux-only. |

**Metamorphic** — a property relating two runs, not a fixed value.

| Gate | What it proves |
| --- | --- |
| `parity-reset` | `ucinewgame` and `Clear Hash` restore engine state, and TT reuse is live — the same position searched again after a reset gives the same result. |
| `parity-skill` | Skill Level 20 is deterministic; Skill Level 0 is random and always legal. |
| `parity-mt` | Threads {2,4} land in a score band around the single-thread golden. |

**Liveness and timing** — the paths a bench never reaches.

| Gate | What it proves |
| --- | --- |
| `parity-stress` | go/stop storms + construct/destroy churn do not hang, race, or crash the thread runtime. |
| `parity-time` | Wall-clock `go movetime` / `wtime` budgets and the clock-scaling invariants hold. |
| `parity-ponder` | `go ponder` → `ponderhit`/`stop` yields a legal bestmove and a clean exit. |
| `parity-valgrind` / `parity-teardown` | Valgrind memcheck across thread counts, and the searchmoves/rootMoves + Worker-clear lifecycle: no definite leak, invalid access, or bad free. Not in `parity` (memcheck is ~20-50x slower); CI runs them in their own job. |

**Structural and diagnostic**.

| Gate | What it proves |
| --- | --- |
| `src-free` | The shipped binary contains zero C++ Stockfish / libc++ symbols. |
| `parity-net-missing` | Starting with no net produces a named diagnostic and a clean non-zero exit — never a signal. |
| `hook-lint`, `arch-report`, `headless`, `loc` | See below. |

## The structural gates

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
or one grew past the line) and nudges if it drops. A small waived set of cohesive
files stays allowed — splitting a cohesive file into coupled micro-files is the
anti-pattern, not the fix.

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
it from disk at startup, which is why every harness run sets `cwd = net/`.

`tools/fetch_net.zig` (`zig build net`) fetches it in pure Zig — no `sh`, no
curl/wget/sha256sum, so it works on every OS. It reads the net name at runtime from
the authoritative Zig constant `default_eval_file_name` in
`src/engine/eval/network.zig`, honoring upstream's name↔contents contract: the file is
named `nn-<first 12 hex of its sha256>.nnue`, so validation recomputes the sha256 and
compares. Sources and order mirror upstream's fetcher. It early-exits when the net is
already present; CI caches it keyed on `network.zig`, so a net bump busts the cache.

`tools/fetch_tb.zig` (`zig build tb`) fetches the 3-man Syzygy set (KPvK KNvK KBvK
KRvK KQvK, WDL + DTZ) into `net/syzygy/` — the tables the `tb-*` gates probe. It
verifies each file's Syzygy magic header, so a mirror's error page cannot masquerade
as a table. Neither the net nor the tables are committed.

## Tracking upstream

`tools/upstream/` holds the state: `UPSTREAM_BASE` (the sha of the last fully-ported
upstream commit — the fork's history is non-ancestral, so this marker, not
`git merge-base`, defines where the port is), `UPSTREAM_TARGET` (the sha being ported
toward), and `upstream_map.tsv` (the blast-radius manifest mapping `src/` globs to
their Zig owner and a risk tier). `tools/upstream/README.md` is the workflow.

| Script | What it does |
| --- | --- |
| `upstream_sync.sh` | The driver: fetch, compute the behind-count from `UPSTREAM_BASE`, print the worklist + tiered backlog and per-commit bench targets. `--check` prints one terse line for a poll. |
| `upstream_oracle.sh` | Builds **vanilla** upstream at a sha into a detached git worktree and prints the binary path. |
| `upstream_parity.sh` | Asserts the native Zig bench == the pristine oracle's bench at the target sha. |
| `upstream_router.py`, `upstream_benchmap.sh`, `upstream_nodes.sh`, `upstream_net.sh` | Classify a commit by Zig owner + risk; list per-commit bench checkpoints; localize which position/commit first diverges; place a bumped net in each worktree. |

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
| `zfish_parity.yml` | push to `main`/`github_ci`, dispatch | `zig fmt --check` over `src/`, `tools/`, `build.zig` — cheap, first, blocks the rest. **Linux x86-64 parity**: `zig build parity`, `test`, `test -Doptimize=ReleaseSafe`, `fuzz` smoke, `parity -Doptimize=ReleaseSafe`, and `tools/arch_determinism.sh` (the same signature on every tier the runner can execute). **Linux aarch64 parity** on a native arm64 runner: the `@Vector` NNUE lowers to NEON with no source changes and must bench identically. **native-os matrix** (Windows x86-64, Windows aarch64, macOS aarch64, macOS x86-64): builds natively and runs `zig build parity-portable`. **Linux valgrind memcheck**: `parity-teardown` + `parity-valgrind`, pinned to the baseline tier. **Zig master compatibility**: non-blocking. |
| `zfish_fuzz.yml` | nightly schedule, dispatch | `zig build fuzz --fuzz` under `ReleaseSafe` for a bounded budget, mutating toward new coverage over FEN-parse → `generateLegal` → make/unmake. A SIGINT at the budget with no crash passes; a target crash fails early with the safety-check trace and the reproducer. |
| `zfish_upstream_check.yml` | weekly schedule, dispatch | Fetches `official-stockfish/master` and prints how many commits the port is behind `UPSTREAM_BASE`, into the job summary. Detection only — always exits 0. Porting stays a deliberate, human-gated session. |

The **Zig master compatibility** lane runs the full Linux parity suite under a
**pinned** Zig master snapshot with `continue-on-error: true`. It is informational:
it reports its real pass/fail in the UI but never fails the workflow, because master
is a moving target that can break through no fault of this repo. The snapshot is
pinned rather than floating so the lane flags this repo's regressions instead of
flapping on upstream's in-flight work, and it is bumped by hand after the port is
verified locally. Its value is early warning on the road to the next toolchain bump.

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
SIGILLs. It reports instructions (the work) and cycles/IPC/cache-misses (the
efficiency) at native speed, which neither wall-clock A/B (thermally noisy) nor
callgrind (deterministic instructions, sse41 only, ~50x slowdown) can do together.

It is a **local gate, not CI**: it measures the host it runs on, and a hosted runner's
shared, thermally-uncontrolled CPU cannot carry a performance verdict. The same holds
for the other local scripts (`nps_ab.sh`, `perf_callgrind.sh`,
`perf_fingerprint.py`) and for the local-only `tb-cursed` gate, which needs 5-man
tables that are never fetched in CI.
