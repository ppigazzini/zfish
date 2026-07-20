# Architecture

How the code is structured: the zones, how they depend on each other, and how one
search flows through them. For building, the bench gate, and the validation
commands, see [README](../README.md) and [CONTRIBUTING](../CONTRIBUTING.md); for the Zig
patterns behind the hot path, see [docs/idiomatic-zig.md](08-idiomatic-zig.md).
Per-module detail lives in each file's `//!` header.

This page states structure, not numbers. Where a count would date it (edges,
coupling), run `zig build arch-report` for the live value.

## The three zones

`src/` splits by responsibility, each a directory:

| Zone | Path | Owns | May import |
| --- | --- | --- | --- |
| **engine** | `src/engine/` | the chess library: board, movegen, search, NNUE eval, per-worker state | nothing outside `engine/` |
| **platform** | `src/platform/` | the OS/HW runtime: threads, memory, NUMA, Syzygy, the clock | `engine/` |
| **shell** | `src/shell/` | the process: UCI parsing, the option model, `main`, the engine object | `engine/`, `platform/` |

The stack is `shell → platform → engine`, engine at the bottom. `platform/` is not a
layer *beneath* the engine — it depends *on* engine, because `thread.zig` and
`search_thread.zig` manage `Worker` objects. It is the runtime that *hosts* the
engine library, not a base the engine sits on.

```mermaid
flowchart TD
    shell["shell/ — the process"]
    platform["platform/ — the OS/HW runtime"]
    engine["engine/ — the chess library"]

    shell --> engine
    shell --> platform
    platform --> engine
    platform -.->|thread.zig imports option| shell

    style engine fill:#1f6f3f,color:#fff
```

**`engine/` is a library.** The transitive closure of every engine module stays
inside `engine/`. It compiles and tests standalone — `zig build engine`, rooted at
`src/engine/headless.zig`, links no platform or shell. The one dashed edge above
(`platform/thread.zig` importing `shell/option`) is the only edge keeping the zone
graph from a strict DAG; the engine avoids the same import through a hook seam.

## The module graph

`build.zig` is not a script that discovers files. It is a **hand-declared module
graph** — a `module_edges` table of `.{ .from, .imp, .to }` triples wired by
`addImport`, and the authoritative statement of what may depend on what. A module
cannot reach a peer it was not handed.

**A declared edge is a permission, not a fact.** `addImport` grants the right to reach a
module; it does not oblige anyone to use it. So the table is always a superset of the real
dependencies, and `arch-report` reports the difference — for the composition root it prints
`main.zig: wired N, @imports M -> N-M DECLARED-BUT-UNUSED edges` and names each one. Those
are not errors, and the count is expected to be non-zero.

They are also not free. A dead declared edge is a **pre-granted permission**: while it
stands, a stray `@import` of that module compiles silently; delete it and the same import
becomes a compile error. That is the only enforcement — the compiler will not otherwise stop
a module reaching a peer the design never intended it to touch. So prune an edge when its
last real use goes, and treat a growing unused list as permissions accumulating faster than
anyone is spending them.

Read the counts from `zig build arch-report`, never from prose: they move with every added or
deleted import, and any number written here is stale by the next commit.

The module graph is a **DAG**. The file graph (relative `@import` inside a module)
holds exactly one cycle, `search_main.zig ↔ search_back.zig` — the alpha-beta
recursion itself (`searchImpl ↔ runBack`), declared as one component in both file
headers. **Zig permits import cycles at both granularities**, so the DAG is a design
outcome, not a language guarantee. `zig build arch-report` prints both graphs and
trips on a broken module DAG or an undeclared file cycle.

### The composition root and the cycle-break hooks

The DAG rests on one pattern. `main.zig` is a **composition root**: it may import
everything and is imported by nothing. That asymmetry lets it hand implementations
*backwards* to leaf modules that could not import them.

Where a cycle *would* exist, a leaf declares a function-pointer **hook**, and the
composition root registers the real implementation at startup:

```zig
// Leaf (engine/search/time_source.zig): declare the seam.
pub var now: *const fn () i64 = &defaultNow;

// Composition root (shell/main.zig): inject the real clock at startup.
time_source.now = &clock.now;
```

This is dependency injection through function pointers — the reason the graph below
`main` is acyclic by construction, and how `engine/` reaches an OS clock while
importing no platform module. `main.zig` registers most hooks; `position.zig`
self-registers the two it owns. `zig build hook-lint` bounds them: it ratchets the
count and requires each to declare its failure mode when unregistered. See
`src/platform/runtime_hooks.zig` and the `//! hook-class:` headers.

### Does the DAG cost performance?

No — the DAG and its hooks are a *source-level* structure (for cycle-freedom, the
standalone `engine/` library, and testability), not compilation-unit boundaries, and
they do not tax the search. Three reasons, each measured against a full bench:

- **Zig is whole-module.** Every `@import` lowers into one LLVM module, so the
  compiler inlines across module boundaries exactly as it would within a single file
  — a C codebase splits into translation units the linker must reconcile; zfish does
  not. Proven by building `-Dlto=false`: every hot cross-module call stays inlined, no
  small accessor (`sqBb`, `kingSquare`, `pawnAttacks`) shows up as its own symbol, and
  the profile's top functions are unchanged.
- **The hooks are wired at startup and stay off the hot path.** A function pointer is
  an optimizer barrier only *where it is called*. In the call graph over a full bench,
  every per-node symbol is a direct engine call; the one hook reached inside the
  search is the clock (`time_source.now`), which `checkTime`'s counter throttles to
  about one call per 512 nodes. Eval reads the network as startup-loaded data through
  a direct call, not a hook, and the per-node path allocates nothing.
- **Comptime replaces runtime indirection where it would be hot.** The search and the
  move scorer are specialized at `comptime` on node type and generator kind, so those
  dispatches resolve at compile time.

So the architecture costs **startup wiring**, not nps. It would only cost the search
if a hook were placed on the per-node path un-throttled — which is exactly what the
measurement discipline and `hook-lint` guard against.

**Is LTO required for this?** No. The whole-module inlining above is independent of
LTO — it is why the macOS and Windows builds ship with `-Dlto=false` permanently and
stay bit-exact. LTO (default on for Linux, matching upstream's `-flto=full`) buys a
separate ~4% by optimizing across the one boundary Zig does not compile itself: the
`compiler_rt` / libc runtime (`memcpy` / `memset` in the accumulator). The pure-Zig
affine kernel is bit-identical in instructions with LTO on or off; only the
libc-touching paths move. LTO is a codegen win to match upstream, not the thing that
makes the module graph free.

## How a search flows

```mermaid
flowchart TD
    M["shell/main.zig<br/>install hooks · construct engine"]
    S["shell/session.zig<br/>options · load net · size threads"]
    T["platform/thread.zig<br/>Worker threads"]
    ID["engine/search_driver<br/>iterative deepening"]
    AB["engine/search_main ↔ search_back<br/>alpha-beta (the file cycle)"]
    MP["engine/movepick.nextMove"]
    EV["engine/evaluate → nnue_inference<br/>@Vector SIMD"]

    M --> S --> T
    T -->|per worker| ID --> AB
    AB -->|moves| MP
    AB -->|leaf eval| EV
    AB -->|recurse| AB
```

`main` installs the hooks and constructs the engine; `session` registers UCI
options, loads the net, and sizes the pool; each `platform/` worker runs the
engine's iterative-deepening driver, which recurses through `searchImpl ↔ runBack`,
pulling moves from `movepick` and leaf evaluations from the `@Vector` NNUE. Nothing
on that path allocates.
