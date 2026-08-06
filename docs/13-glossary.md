# Glossary

The words the rest of this set uses without stopping to define them, in tiers that must not be
confused:

- **Section 1 is Stockfish's vocabulary.** Upstream owns the word; the entry says which symbol
  carries it here. It does not teach the concept — a page in this set describes what this
  codebase does, and the domain reference is a link in [11-references](11-references.md).
- **Section 2 is this repository's vocabulary.** None of it appears in the Stockfish source,
  and upstream is not obliged to agree with any of it.
- **Section 3 is the words that mean two things here.** Each entry disambiguates rather than
  defines.
- **Section 4 is the testing field's vocabulary.** Neither tree owns it; the literature does,
  which is what makes it worth using. A term there is searchable outside this repository, and a
  step name is not.

A reader who cannot tell which tier a word is in will grep the Stockfish source for `zone` and
not find it.

Every entry names the file, symbol or step that owns it, and none quotes a number a gate
computes.

**The limit.** This page defines terms; it does not explain subsystems. For how a search flows,
see [00-architecture](00-architecture.md); for what a step proves, [10-tooling-ci](10-tooling-ci.md);
for what a quantity denotes and why so few of them are types, [09-type-design](09-type-design.md).

## 1. Upstream's word, and what carries it here

Grep the symbol if a citation misses — the owners move faster than the definitions do.

| term | what carries it here |
|---|---|
| **bench** | the fixed position script the anchor is a fact about: `src/shell/bench_positions.zig`, upstream's `Defaults` list entry for entry, driven by `src/shell/benchmark.zig`. Changing an entry is a behaviour change that cannot be compared against upstream afterwards |
| **the bench signature** | the node total that run prints, asserted by `zig build signature`. The *number* lives in `build.zig`'s `signature_reference` and in no page — `docs-lint` fails a page that quotes a different one |
| **node** | one execution of a node body: `searchImpl` in `src/engine/search/search_main.zig` for alpha-beta and `qsearchImpl` in `src/engine/search/search_qsearch.zig` for quiescence, each specialized at `comptime` on `NodeKind`. **Not** a NUMA node; see Section 3 |
| **`Value`, `Key`** | a score and a Zobrist word, each a plain integer rather than a distinct type. That is a decision with measurements behind it, not an omission: [09-type-design](09-type-design.md) says why a wrapper costs more here than it catches, and Zig has no operator overloading to soften it |
| **depth** | a plain `i32`, for the same reason — a depth-scaled product feeds several codomains, so a type carrying its unit through one breaks the rest |
| **the root, PV, MultiPV** | the root move list is `RootMove` records (`src/engine/state/root_move.zig`); `src/engine/search/search_emit.zig` prints one `info` line per PV line, and `MultiPV` is how many there are |
| **currmove** | `info depth D currmove M currmovenumber N`, the root move now being searched. `searchCbRootOnIter` emits it, from the main thread only and only past `id_nodes_limit_output` (`src/engine/search/search_values.zig`) — which is why no bench and no golden reaches it, and why the transcript case that does declares a hold |
| **the accumulator** | the incremental half of the NNUE evaluation, `src/engine/eval/nnue_accumulator.zig`. Slot `i` of its stack holds the position at ply `i`, and every make/unmake owes it a bracket; [03-engine-eval](03-engine-eval.md) owns the invariant. It is worth measuring rather than assuming — the incremental design is ablatable with `-Dacc-refresh-only` |
| **the feature transformer** | the first NNUE layer, `src/engine/eval/nnue_ft.zig`, stored as one byte blob. Its region offsets are derived **once** and read by both the parse and the accessors, because two spellings of one layout is a layout that can disagree with itself |
| **WDL, DTZ** | the two Syzygy probe results — win/draw/loss, and distance to zeroing. The prober is `src/platform/syzygy/`, and `d` prints both once a `SyzygyPath` covers the position |
| **cursed win, blessed loss** | a win or loss whose DTZ exceeds the 50-move counter, so the result is a draw in play. Only a 5-man table reaches them, which is why `tb-cursed` is a separate local-only gate — CI never fetches those tables, so its golden ages with no alarm |
| **Lazy SMP** | the threading model: N workers over one root sharing the transposition table. Each worker's state is one `WorkerLayout` block (`src/engine/state/worker_layout.zig`), the pool is `src/platform/thread_pool.zig`, and thread 0 is the main thread — the one that reports |
| **the transposition table** | `src/engine/search/tt.zig`, in clusters. `depth8` is a `u8` and `depth8 != 0` **is** the occupancy test, so `entryPenalize`'s saturating decrement is load-bearing: a wrapping one turns a penalised shallow entry into the deepest entry in the table |
| **the history block** | the main, capture, continuation and correction tables (`src/engine/search/history.zig`). A key selects a plane, and the two selectors that pick a continuation plane are named types (`InCheck`, `WasCapture`) because a swap of two adjacent `u8`s does not fault — it addresses a valid entry of the wrong thing |

### The port map is the other direction of this table

Section 1 answers "upstream says X, what is it here?". The reverse — "upstream's
`search.cpp:2088`, where did it land?" — is answered by `tools/upstream/upstream_map.tsv`.

## 2. This repository's vocabulary

None of these appear in the Stockfish source. Where a tool owns the definition, the tool wins.

| term | what it is |
|---|---|
| **zone** | one of the three directories the dependency rule is stated over: `src/engine/` (the chess library), `src/platform/` (the OS runtime), `src/shell/` (the process). `tools/headless_lint.sh` holds `src/engine/` to importing only `src/engine/`, and `zig build engine` builds and tests that graph with no platform and no shell under it |
| **hook, hook seam** | the indirection through which one zone reads a value another zone owns, so the dependency does not run backwards — `option_source.zig`, `time_source.zig`, `tb_source.zig`, `tb_extend_source.zig` and `output_sink.zig` under `src/engine/search/`, plus the lifecycle table in `src/platform/runtime_hooks.zig`, all installed at startup by the composition root (`src/shell/main.zig`). Each answers with a headless default when nothing registers, which is what keeps the engine zone runnable alone; `hook-lint` holds every one to a declared failure mode and class |
| **gate** | a build step that **asserts** and exits non-zero when the assertion breaks. A step that only builds, measures or re-derives is not one, and says so in `tools/lane_excuses.txt` so `lane-coverage` can tell the two apart. A gate whose tool is missing is **skipped**, which is not a pass |
| **lane** | one independently driven run. Usually a CI job under `.github/workflows/` — `lane-coverage` holds every dispatched step to being in an aggregate, named by a workflow, or excused — and also one target inside a step that drives several. A SIMD lane is a different word; see Section 3 |
| **the anchor** | the bench node total, pinned as `signature_reference` in `build.zig`. It is a **bit-exactness** claim against upstream, not a local snapshot, so a change that moves it must say what moved it |
| **the oracle** | a pristine upstream build, produced by `tools/upstream_oracle.sh`, that the local differentials drive beside zfish. It is **always** the zig-c++ build: a `gcc` oracle measures gcc, not zfish. **LOCAL** — a CI checkout carries none, so every step needing one says so |
| **the finish line** | `zig build upstream-parity` — zfish's bench against that build. The anchor says the number has not moved; the finish line says the number is upstream's |
| **sibling** | `../mcfish`, `../rfish`: peer ports of the same upstream. **None is a source and none is behind another**, so a finding in one is a hypothesis about this tree, to be probed here before it is fixed here — a sibling's perf result in particular is a claim about *its* compiler |
| **sweep** | driving one question across a whole class rather than fixing the instance in front of you: every hook, every named path, every sibling commit in a window. A **sibling sweep** is that second case, each finding probed against this tree before anything is written |
| **the spine** | the engine with the network removed — the board, state and search machinery a `-Dstub-eval` build leaves running. A **spine comparison** is that pair of builds measured against the oracle patched with the same formula (`tools/material_eval.sh`, `tools/upstream/material_eval.patch`): it localises an effect by removing a component rather than attributing one |
| **tier** | an ISA target the build selects, chosen by `-Darch`. A measurement is a fact about **one** tier, and `native` names a different tier on every host, so a result carries the tier it was taken at |
| **knob** | a build option that produces a **deliberately different** binary for measurement — `-Dstub-eval`, `-Dacc-refresh-only`, `-Dno-threat-record`. Not UCI options and not shipped behaviour: a knob build plays badly or skips work on purpose |
| **the budget** | `tools/perf_budget.sh`, which holds retired instructions to a per-tier row in `tools/instr_budget.golden`. It is an **absolute** count, which is what makes it gateable where a cycle count is not, and what lets it catch the regression class the node signature and every ratio cancel out. Toolchain-specific and local-only, so a Zig upgrade moves it legitimately and nothing in CI will tell you. Section 3 for the other budget |
| **golden** | a `tools/*.golden` file: a photograph of what zfish printed, declared in `build/gates.zig` and diffed by its gate. `golden-coverage` globs `tools/` and holds every file found to a reader, in both directions, because a photograph nobody diffs is a file rather than a check |
| **transcript case** | one command script driven through both engines by `tools/upstream_transcript.sh`, whole output diffed. A `# hold <seconds>` line — a comment to both engines — turns the wait into a deadline for a case whose search needs one, and the case that reaches the `currmove` threshold is the reason it exists |
| **rig fault** | the verdict that the comparison **did not happen**: both sides blank, a case that never answered inside its hold, a subject that came back under its floor. Neither a pass nor a failure, it exits 2 and is reported before any standing — a run that compared nothing must not publish the standing of what it did compare |
| **known divergence** | an argued regex in `tools/transcript_known.txt`, tagged `EXPIRING` or `PERMANENT`, one pattern per side. An `EXPIRING` entry matching nothing fails the gate: a filter that outlives its cause is how a differential quietly stops comparing |
| **fact table** | a file of facts about chess rather than about zfish. `tools/perft.golden` is the one, and the name it carries is the trap: a mismatch there is always a movegen bug, never an update candidate |
| **oracle-derived, self-golden** | which engine a golden was driven from. `tools/upstream_golden_audit.sh` drives the **oracle**, so what it blesses is upstream's bytes; a `<gate>-update` drives **zfish**, so what it writes pins a defect exactly as faithfully as correct behaviour — which is why it refuses by default and names the audit instead |
| **ratchet** | a recorded count a gate holds to one direction of travel. `hook-lint` holds the hook count to an exact baseline, so it fails on a hook **added** and on one removed alike — hooks buy the DAG and are its running bill, so either way somebody decided something. `upstream-map` ratchets the uncovered upstream surface and the drift from `tools/upstream/upstream_map.baseline`: lower it as citations land, never raise it. The direction is stated rather than assumed, because a baseline that only ever grows stops describing anything |
| **the ledger** | the commit log, read as the record of what has already been measured. Every `perf(...)` commit carries its evidence in its body, including the refutations, so `git log --grep` finds an idea that has already been tried and measured negative here |
| **fleet** | several agents working in parallel, chartered onto **disjoint files** rather than disjoint metrics, delivering candidate commits an integrator re-gates on clean `main` |
| **quiet box, the A/A floor** | an idle machine, and the noise floor obtained by A/B-ing a binary against a byte-identical copy of itself. Each axis has its own floor — [08-idiomatic-zig](08-idiomatic-zig.md) records them — and a change smaller than the floor of the axis you measured is not a result |

## 3. Words that mean two things

| word | meaning A | meaning B |
|---|---|---|
| **golden** | a `tools/*.golden` file: a pinned transcript of what **zfish** printed | the upstream tree that defines correct behaviour, which is what a golden gets *audited* against. Nothing makes the two agree by construction — `tools/upstream_golden_audit.sh` re-derives from the oracle, a `<gate>-update` from this engine |
| **oracle** | the pristine upstream build the differentials drive | the testing-field term in Section 4: whatever decides that a result is correct |
| **node** | one search node body | one NUMA node: a set of CPUs in the config `src/platform/numa/` builds from the system, which `NumaPolicy` overrides |
| **lane** | one CI job, or one target inside a step that drives several | one SIMD lane of a `@Vector`: one element position of the vector LLVM lowers to the tier's registers |
| **source** | a `*_source.zig` hook seam, so a value the engine zone reads through an indirection | "the source" a port was made **from** — which no sibling is |
| **sweep** | a class swept across the tree, or a sibling's log across a window | a gate's own pass over its inputs: the transcript loop over its cases, the arch gate over its tiers |
| **budget** | the per-tier instruction budget `perf-budget` holds | the search's own time budget, which `src/engine/search/timeman.zig` resolves once per `go` |
| **key** | a Zobrist word off the position | the material key a Syzygy probe hashes its table by, and the pawn and correction keys that select a history plane. [09-type-design](09-type-design.md) maps the family: one `u64`, several spaces, no shared arithmetic |
| **stack** | the search's per-ply `SearchStack`, the `ss` every node body indexes | the NNUE accumulator stack, one slot per ply, pushed and popped by the make/unmake bracket |
| **worker** | one `WorkerLayout` block: the per-thread search state | the OS thread the pool spawns and NUMA binds. One block per thread, and neither word implies the other |
| **bench** | the UCI command | the position list it runs, and the node total that run produces. "The bench moved" is ambiguous between all three; say which |

## 4. The testing field's vocabulary

No file in either tree defines these. They are worth learning as names rather than
descriptions: each is the handle for a known failure mode, and the last two describe checks that
are worse than absent.

| term | what it means | what it is here |
|---|---|---|
| **oracle** | whatever decides that an observed result is correct | the pristine upstream build, `tools/perft.golden`, a sanitizer report, or nothing at all |
| **differential testing** | drive two implementations with one input and diff | `upstream-parity`, `tools/upstream_transcript.sh`, `tools/upstream_golden_audit.sh`, and the random-walk node counts `tools/upstream_walk.py` takes on positions nobody chose |
| **characterization test** | pins *current* behaviour, and is explicitly not a correctness claim | every `tools/*.golden`, which is why one re-derived from zfish rather than from the oracle proves only that zfish still agrees with itself |
| **metamorphic relation** | a property relating two runs, rather than a pinned value | the per-tier net round-trip in `tools/arch_determinism.sh`: write the resident net out on every tier and require the same bytes back |
| **implicit oracle** | needs no reference, because some outcomes are wrong on their face | the fuzz targets, where the finding is the crash, and `zig build test -Doptimize=ReleaseSafe`, where it is the trapped overflow the shipped build would have wrapped |
| **mutation testing** | inject the defect, and require the check to go red | `tools/negative_control.sh` is the automated form, one mutant per gate; the "seen to fail" table in a gate's commit body is the by-hand one |
| **lost test** | a check that exists and is in no suite the build runs | a step in no lane and no aggregate (`lane-coverage`), and a golden no gate reads (`golden-coverage`). Both have their own gate here for exactly this reason |
| **false pass** | a run that passed because it compared **less**, not because more was right | the both-blank refusal in the transcript gate, the floor checks on a globbed subject, and a fixture-guarded test that skips when its fixture is absent — check the skipped count, because a gate that reports OK over nothing reads exactly like one that checked everything |
| **negative control** | a run against the **defective** tree that must show the defect, proving the check can fail at all | `tools/negative_control.sh`, which mutates the tree once per gate, requires that gate to exit non-zero, then restores and requires it to pass. A gate that has never fired is not a gate |
