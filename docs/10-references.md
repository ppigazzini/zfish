# References

External material this codebase is built against, and the design references behind
its structure.

## Upstream

| Reference | Use |
|---|---|
| [Stockfish](https://github.com/official-stockfish/Stockfish) | The engine zfish ports. The source of all chess strength, the search and evaluation behaviour zfish reproduces bit-exactly, and the NNUE networks. No Stockfish C++ is vendored here; the differential check builds pristine upstream in a throwaway git worktree — see [09-tooling-ci.md](09-tooling-ci.md). |
| [Stockfish docs](https://official-stockfish.github.io/docs/stockfish-wiki/Home.html) | Engine behaviour, UCI options, and terminology. |
| [Stockfish commit history](https://github.com/official-stockfish/Stockfish/commits/master) | The authority for a bench-moving change. A sync ports a real upstream commit and lands bit-exact at that commit's `Bench:`. |

## Zig

| Reference | Use |
|---|---|
| [Zig language reference](https://ziglang.org/documentation/0.16.0/) | `comptime`, `@Vector`, `@splat`, builtins, and the semantics the hot path relies on. |
| [Zig build system](https://ziglang.org/learn/build-system/) | Modules, `addImport`, per-module tests — the artefact `build.zig` is. See [00-architecture.md](00-architecture.md). |
| [Zig standard library source](https://github.com/ziglang/zig/tree/master/lib/std) | The authority when an API differs across supported versions. Read the std source, not a changelog. |
| [Ghostty — useful Zig patterns](https://mitchellh.com/writing/ghostty-and-useful-zig-patterns) | Comptime interfaces for platform/arch dispatch, and the caveat that CI must build every option or a configuration rots. |
| [TigerBeetle `TIGER_STYLE.md`](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) | Static allocation and near-zero dependencies — the hot-path discipline in [08-idiomatic-zig.md](08-idiomatic-zig.md). |

## Chess domain

| Reference | Use |
|---|---|
| [UCI protocol](https://backscattering.de/chess/uci/) | The command and option surface the shell implements — see [07-shell.md](07-shell.md). |
| [Chess Programming Wiki](https://www.chessprogramming.org/Main_Page) | Alpha-beta, transposition tables, move ordering, magic bitboards, SEE — the algorithms in [01-engine-board.md](01-engine-board.md) and [02-engine-search.md](02-engine-search.md). |
| [NNUE (Chess Programming Wiki)](https://www.chessprogramming.org/NNUE) | The efficiently-updatable network architecture in [03-engine-eval.md](03-engine-eval.md). |
| [Leela Chess Zero training data](https://storage.lczero.org/files/training_data) | The data the NNUE networks are trained on, under the [ODbL](https://opendatacommons.org/licenses/odbl/odbl-10.txt). |

## Design

| Reference | Use |
|---|---|
| John Lakos, *Large-Scale C++ Software Design* (1996) / *Volume I* (2019) | Physical design: components, levelization, escalation for breaking cycles, and the CCD/ACD/NCCD coupling `zig build arch-report` prints. |
| [Mark Seemann — Composition Root](https://blog.ploeh.dk/2011/07/28/CompositionRoot/) | The pattern `main.zig` implements: one place that may reference everything, referenced by nothing, wiring implementations into the leaves at startup. See [00-architecture.md](00-architecture.md#the-composition-root-and-the-cycle-break-hooks). |
| David L. Parnas, *On the Criteria To Be Used in Decomposing Systems into Modules* (CACM 15(12), 1972) | Information hiding — the criterion the zone split meets. |
