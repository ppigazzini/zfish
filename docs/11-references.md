# References

External material this codebase is built against, and the design references behind
its structure.

## Upstream

| Reference | Use |
|---|---|
| [Stockfish](https://github.com/official-stockfish/Stockfish) | The engine zfish ports. The source of all chess strength, the search and evaluation behaviour zfish reproduces bit-exactly, and the NNUE networks. No Stockfish C++ is vendored here; the differential check builds pristine upstream in a throwaway git worktree — see [10-tooling-ci.md](10-tooling-ci.md). |
| [Stockfish docs](https://official-stockfish.github.io/docs/stockfish-wiki/Home.html) | Engine behaviour, UCI options, and terminology. |
| [Stockfish commit history](https://github.com/official-stockfish/Stockfish/commits/master) | The authority for a bench-moving change. A sync ports a real upstream commit and lands bit-exact at that commit's `Bench:`. |

## The sibling ports

Three trees carry the same engine beside this one, and a large share of the process rules in
[AGENTS.md](../AGENTS.md) was paid for in one of them:

| Tree | What it is |
|---|---|
| `../mcfish` | a C23 port of the same upstream, bit-exact against the same anchor. |
| `../rfish` | a Rust port, the same. |
| `../Stockfish`, branch `refish` | **not a port** — a refactoring branch of upstream's own C++, carrying a register of defects found in upstream `master`. Its findings are about the GOLDEN, so one it records may be a defect zfish holds *because* it was faithful — a different question from the one the two ports answer. |

**None of them is a golden.** The differential reference is always upstream, built by
`tools/upstream_oracle.sh`; a sibling agreeing with zfish says only that two ports made the
same choice.

### How to sweep them

**A sibling's finding is a hypothesis about this tree, not a diff to apply**, and the first
thing to read is the sibling's own attribution — a candidate is often this tree's own work
coming home, and a sweep that skips that step spends its session re-porting itself.
`tools/perf_counters.zig`'s workload guard is the shape to expect: `../mcfish` took the
budget half of that check from here, then found that the A/B half had never had it, and what
came back was the half zfish was missing rather than the idea it already had.

**A measurement does not transfer, in either direction.** `../rfish` outlined its move
picker's three stage setups and measured a win on both tiers. The identical change here, its
mechanism reproduced exactly, retired **more** instructions on both — the prologue cost it
removed does not exist in this tree
([08-idiomatic-zig.md](08-idiomatic-zig.md#do-not-outline-a-cold-body-to-shrink-a-hot-frame)
carries the numbers and the rule). Take the idea; price it here.

**A sibling's GATE is a hypothesis about what this tree does not INSTRUMENT** — which is a
different question from whether the same defect is here, and usually the more productive one.
The gate with **no analogue** is worth more than the gate that is better. Four ported from
`refish` in one window — a shell lint over the gate scripts, source reach, liveness and type
refusal — and each found a real defect on its first run; the shell lint found five, three of
them a `cd` with no `|| exit` inside the gate drivers themselves, which would have run the
lint in the caller's directory and reported nothing wrong.

**A defect register is swept per CLASS, not per entry.** An entry names a defect and the one
site where it was found; grep the class and expect the second site to be in another zone. Nor
does the sibling's reproducer carry over: upstream overflows `movestogo` at `mtg - 1`, which
zfish widens to `i64` first, so that entry read as closed here — while a negative
`movestogo` drove the same clock into a negative optimum and answered a full clock from a
depth-4 search. The defect was real and had to be re-derived rather than replayed.

**A register swept once is not a register swept.** The 2026-08-15 sweep read every `fix`
commit on that branch and closed the register; a second campaign landed in the days after it,
and the 2026-08-18 sweep found six more live defects plus a Syzygy decoder win in a tree the
first had reported clean.

## Zig

| Reference | Use |
|---|---|
| [Zig language reference](https://ziglang.org/documentation/0.16.0/) | `comptime`, `@Vector`, `@splat`, builtins, and the semantics the hot path relies on. |
| [Zig build system](https://ziglang.org/learn/build-system/) | Modules, `addImport`, per-module tests — the artefact `build.zig` is. See [00-architecture.md](00-architecture.md). |
| [Zig standard library source](https://github.com/ziglang/zig/tree/master/lib/std) | The authority when an API differs across supported versions. Read the std source, not a changelog. |
| [Ghostty — useful Zig patterns](https://mitchellh.com/writing/ghostty-and-useful-zig-patterns) | Comptime interfaces for platform/arch dispatch, and the caveat that CI must build every option or a configuration rots. |
| [TigerBeetle `TIGER_STYLE.md`](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) | Static allocation and near-zero dependencies — the hot-path discipline in [08-idiomatic-zig.md](08-idiomatic-zig.md). |
| [matklad — Newtype Index Pattern in Zig](https://matklad.github.io/2025/12/23/zig-newtype-index-pattern.html) | The sized-enum newtype (`enum(u32) { _ }`, `@intFromEnum`/`@enumFromInt`) that `encode.TbFile` is an instance of, and its stated limit: the conversion is open, so the pattern stops a confusion rather than an intent. |
| [Zig issue 12524 — niche packing for optional enums](https://github.com/ziglang/zig/issues/12524) | Why `?E` is wider than `E` here even when the tag leaves values unused, and therefore why the board keeps in-band sentinels. |
| [Zig issue 1595 — request: distinct types](https://github.com/ziglang/zig/issues/1595) | The standing discussion of a first-class distinct-type feature. Zig has none, so the sized enum above is the whole instrument, and the absence is why [09-type-design.md](09-type-design.md) can guarantee so little. |
| [Zig issue 21946 — `@enumFromInt` and non-exhaustive enums](https://github.com/ziglang/zig/issues/21946) | The conversion into an open sized enum is not range-checked, which is the mechanical statement of "the pattern stops a confusion, not an intent". |

## Type theory and type design

The theory behind [09-type-design.md](09-type-design.md). Each entry says what it is *for*
here — several shape a decision without any of their machinery being run, and one group is
named only so the frontier is on the record. **Do not read a citation as a claim that zfish
implements what the paper describes.**

### Why a type can remove a check — and why that argument does not apply here

| Reference | Use |
|---|---|
| [Xi & Pfenning — Eliminating Array Bound Checking Through Dependent Types (PLDI 1998)](https://www.cs.cmu.edu/~fp/papers/pldi98dml.pdf) | The canonical result: index and array types carrying a static size let a checker discharge the bound and emit no check. Named to mark the boundary — **the shipped binary is ReleaseFast, so there is no bound check for a type to remove.** The mechanism zfish gets instead is a comptime-known length, and the payoff is what the compiler does with the *fact*, not a deleted branch. |
| [Xi & Pfenning — Dependent Types in Practical Programming (POPL 1999)](https://doi.org/10.1145/292540.292560) | Dependent ML, the language the above became. Guiding only. |
| [Jhala & Vazou — Refinement Types: A Tutorial (2021)](https://doi.org/10.1561/2500000032) | The modern form of the same idea: a type refined by a predicate over its value. The thing zfish argues in doc-comments (`lane < 64` because it came from `@ctz`) and cannot state. |

### Making the wrong value unwriteable

| Reference | Use |
|---|---|
| [Wlaschin — Designing with types: making illegal states unrepresentable](https://fsharpforfunandprofit.com/posts/designing-with-types-making-illegal-states-unrepresentable/) | The canonical write-up of the maxim behind `ScoreKind`'s three variants: a decisive score is a fact, not an estimate, and three variants make blending one unwriteable rather than discouraged. |
| [King — Parse, Don't Validate (2019)](https://lexi-lambda.github.io/blog/2019/11/05/parse-don-t-validate/) | Push the check to the boundary and let the *result type* carry that it happened. zfish is a parser at its edges — FEN, UCI, the `.nnue`, a Syzygy table — and the bounded parse in [05-tablebases.md](05-tablebases.md) is this maxim with the safety rules attached. |
| [Kiselyov & Shan — Lightweight Static Capabilities (ENTCS 2007)](https://okmij.org/ftp/Computation/lightweight-static-guarantees.html) | A capability type witnesses a checked property so downstream code need not re-check it. The lens for "this handle grants access to that table", which is what `AccumulatorStack` being an `opaque` handle rather than a bare pointer is doing. |
| [Noonan — Ghosts of Departed Proofs (Haskell 2018)](https://kataskeue.com/gdp.pdf) | Preconditions carried as proofs in phantom type parameters, at no runtime cost. The diagnosis, not the machinery: the four correction accessors exist because the proof "this key selects this counter" was real, was written in a comment, and was carried by nothing. |

### Boolean blindness, and states that should not be representable

| Reference | Use |
|---|---|
| [Harper — Boolean Blindness (2011)](https://existentialtype.wordpress.com/2011/03/15/boolean-blindness/) | *"There is no information carried by a Boolean beyond its value; to make use of one you have to know its provenance."* The moment you branch on a `bool` the meaning of what was tested is gone. The canonical source for why `NodeKind` replaced two booleans, and for why `cut_node` remaining a `bool` is recorded as a known gap rather than a settled design. |
| [Minsky — Effective ML, "make illegal states unrepresentable" (2010)](https://blog.janestreet.com/effective-ml-video/) | Where the slogan comes from. The concrete instance here: two independent booleans admit four states and the search means three, so the fourth was writeable until a three-variant enum replaced them. |
| [Making invalid states unrepresentable: why boolean flags are bugs in disguise](https://blog.rafaelfernandez.dev/posts/making-invalid-states-unrepresentable-1-boolean-flags/) | The worked modern write-up of exactly that arithmetic — *n* independent flags give 2ⁿ states and a domain rarely has 2ⁿ meanings. Useful as the argument to make when proposing this kind of change. |

### Units, and the quantity that refused one

| Reference | Use |
|---|---|
| [Kennedy — Types for Units-of-Measure: Theory and Practice (CEFP 2009)](https://link.springer.com/chapter/10.1007/978-3-642-17685-2_8) | The system that makes a dimensioned quantity checkable, shipped in F#. Named because it is precisely what a `Depth` type would need and what Zig cannot express. |
| [Kennedy — Types for Units-of-Measure, the F# implementation notes](https://learn.microsoft.com/en-us/dotnet/fsharp/language-reference/units-of-measure) | The shipped realisation, useful as the concrete picture of what a unit-carrying quantity looks like in a working language. zfish's clock is the case it would catch: `elapsed` is milliseconds or node counts depending on `nodestime`, and both are `i64`. Named as the reference, **not** as a candidate — see the sixth map in [09-type-design.md](09-type-design.md) for why that one is documented rather than typed. |
| [Kennedy — Relational Parametricity and Units of Measure (POPL 1997)](https://people.mpi-sws.org/~dreyer/tor/papers/kennedy.pdf) | The theorem behind it — a function polymorphic in units cannot inspect the unit, so the discipline is free. **Unit polymorphism is the feature whose absence refutes `Depth`**: a depth-scaled product lands in six codomains and an operator has one result type. See [09-type-design.md](09-type-design.md#why-there-is-no-depth). |

### The typed index, as production compilers run it

| Reference | Use |
|---|---|
| [matklad — Newtype Index Pattern (2018)](https://matklad.github.io/2018/06/04/newtype-index-pattern.html) | The original statement of the pattern the Zig entry above is the Zig spelling of. |
| [rustc — the `newtype_index!` macro](https://doc.rust-lang.org/nightly/nightly-rustc/rustc_index/macro.newtype_index.html) | The reference implementation at compiler scale, and the reason "an index newtype costs nothing" is the received wisdom. zfish's measured caveat is on the other side of it: free for a *carried* index, not for a value computed with. |

### Zero-cost abstraction, and the measurement that disputes it

| Reference | Use |
|---|---|
| [When Zero Cost Abstractions Aren't Zero Cost (2021)](https://blog.polybdenum.com/2021/08/09/when-zero-cost-abstractions-aren-t-zero-cost.html) | The closest published statement of what [09-type-design.md](09-type-design.md#the-cost-rule) measured: the ideal is difficult to reach in practice, and a wrapper can change what the optimiser does with the enclosing function even when the layout is identical. |

### The frontier — named so it is on the record, not because it applies

| Reference | Use |
|---|---|
| [Hoffmann & Jost — Two decades of automatic amortized resource analysis (MSCS 2021)](https://www.cs.cmu.edu/~janh/assets/pdf/HoffmannJ21.pdf) | Types that carry *potential*, so a cost bound is inferred by type inference. The research line that would answer "why can't the compiler tell me what this type will cost". **The limit is total: AARA bounds algorithmic resource use, not register pressure inside an inlined function, which is what the cost rule actually measures.** Watch it; do not cite it as applicable. |
| [Automatic Amortized Resource Analysis with Regular Recursive Types (2023)](https://arxiv.org/abs/2304.13627) | The state of that line for arbitrary data structures. Same limit. |

## Chess domain

| Reference | Use |
|---|---|
| [UCI protocol](https://backscattering.de/chess/uci/) | The command and option surface the shell implements — see [07-shell.md](07-shell.md). |
| [Chess Programming Wiki](https://www.chessprogramming.org/Main_Page) | Alpha-beta, transposition tables, move ordering, magic bitboards, SEE — the algorithms in [01-engine-board.md](01-engine-board.md) and [02-engine-search.md](02-engine-search.md). |
| [NNUE (Chess Programming Wiki)](https://www.chessprogramming.org/NNUE) | The efficiently-updatable network architecture in [03-engine-eval.md](03-engine-eval.md). |
| [Leela Chess Zero training data](https://storage.lczero.org/files/training_data) | The data the NNUE networks are trained on, under the [ODbL](https://opendatacommons.org/licenses/odbl/odbl-10.txt). |
| [Syzygy tablebases](https://github.com/syzygy1/tb) | The WDL/DTZ format and the probing rules — the reference behind [05-tablebases.md](05-tablebases.md). The file layout is not self-describing, so the format notes are the authority when a probe disagrees with the oracle. |
| [Stockfish's Syzygy prober](https://github.com/official-stockfish/Stockfish/blob/master/src/syzygy/tbprobe.cpp) | The golden for the port. The `tb-*` gates diff against a real upstream build, so this is what a divergence is read against. |
| [Chess960](https://www.chessprogramming.org/Chess960) | Why castling is encoded king-to-own-rook rather than by direction — see [01-engine-board.md](01-engine-board.md#the-move-word). |

## Licensing

| Reference | Use |
|---|---|
| [GNU GPL v3](https://www.gnu.org/licenses/gpl-3.0.html) | zfish is a derivative of Stockfish and inherits its licence. See [Copying.txt](../Copying.txt) and [AUTHORS](../AUTHORS). This is not optional housekeeping: the port reproduces upstream's search and evaluation behaviour, so it is a derived work regardless of the source language. |

## Design

| Reference | Use |
|---|---|
| John Lakos, *Large-Scale C++ Software Design* (1996) / *Volume I* (2019) | Physical design: components, levelization, escalation for breaking cycles, and the CCD/ACD/NCCD coupling `zig build arch-report` prints. |
| [Mark Seemann — Composition Root](https://blog.ploeh.dk/2011/07/28/CompositionRoot/) | The pattern `main.zig` implements: one place that may reference everything, referenced by nothing, wiring implementations into the leaves at startup. See [00-architecture.md](00-architecture.md#the-composition-root-and-the-cycle-break-hooks). |
| David L. Parnas, *On the Criteria To Be Used in Decomposing Systems into Modules* (CACM 15(12), 1972) | Information hiding — the criterion the zone split meets. |
