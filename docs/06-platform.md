# Platform

`src/platform/` is the OS/HW runtime that **hosts** the engine library: threads,
huge-page memory, NUMA topology, Syzygy tablebases, and the monotonic clock. It is
not a layer beneath the engine — it depends **on** engine, because it builds,
drives, clears, and tears down the `Worker` objects the search runs in. The engine
reaches back the other way only through function-pointer seams it declares itself.
For the zones and the module graph, see [00-architecture.md](00-architecture.md).

## Modules

| File | Owns |
| --- | --- |
| `thread.zig` | the pool face: `reconfigure`, `startThinking`, `clear`, pool-wide counters |
| `thread_pool.zig` | the `ThreadPool` footprint: build/teardown of the thread vector, the bound-nodes slice |
| `thread_runtime.zig` | the OS primitives: the futex seam, `Mutex`, `Condition`, `ThreadRuntime` idle loop |
| `search_thread.zig` | the `SearchThread` vehicle: worker handle, job submission, the search job |
| `thread_vote.zig` | the Lazy-SMP vote picking the best thread's move |
| `memory.zig` | the aligned / huge-page allocator and its zero-fill |
| `numa.zig` | the NUMA topology surface (config, binding, execute-on-node) |
| `numa/config.zig` | `NumaConfig`: nodes, CPU sets, `NumaPolicy` parsing, thread distribution |
| `numa/replication.zig` | `NumaReplicationContext` / `NumaReplicatedBase`: the replica registry |
| `tablebase.zig` | the Syzygy facade the engine's `tb_source` seam binds to |
| `syzygy/tables.zig` | file discovery: scan `SyzygyPath`, count `.rtbw`/`.rtbz`, report cardinality |
| `syzygy/registry.zig` | material key → `TBTable`, lazy file load, `set` / `setDtzMap` parsing |
| `syzygy/probe.zig` | the probe data model (`PairsData`, `LR` btree) + `setGroups` / `setSymLen` |
| `syzygy/encode.zig` | position → index geometry (binomials, lead-pawn tables) |
| `syzygy/decode.zig` | file header parsing + the RE-PAIR / canonical-Huffman decoder |
| `syzygy/wdl.zig` | the probe algorithm: `doProbeTable`, `probeTable`, `searchWdl`, `probeDtz`, `mapScoreDtz`, and the surfaces `probeFen` / `probeWdlPos` |
| `clock.zig` | the monotonic millisecond clock |
| `libc.zig` | the thin libc binding (`malloc`, `free`, `exit`) |
| `runtime_hooks.zig` | the lifecycle hook registry (worker build/destroy/clear, setup-state handoff, `shared_state_clear_histories` / `shared_state_insert_history`, `verify_thread_graph`) |

## Threads

### The runtime

`thread_runtime.zig` is self-contained (std only) and holds the only OS-specific
code in the thread stack: a wait/wake-on-address seam —
`futexWait` / `futexWakeOne` / `futexWakeAll` — implemented per owned OS as Linux
`futex(2)`, Windows `RtlWaitOnAddress` / `RtlWakeAddress`, macOS `__ulock_wait` /
`__ulock_wake`. On top of that seam sit a three-state (Drepper) `Mutex` and a
sequence-counter `Condition`; both are platform-independent, and every caller
re-checks a predicate, so spurious wakeups are harmless.

A `ThreadRuntime` owns one `std.Thread` running `idleLoop` on top of that seam. The
idle loop, the job handshake, and the jobs that ride it are covered in
[04-multithreading.md](04-multithreading.md).

### The thread

`search_thread.zig` is the vehicle, not the search body. `SearchThread` holds a tag
at offset 0, the `worker` handle at **offset 8**, the heap `ThreadRuntime` pointer,
and the thread index. `worker@8` is the one field other code reads off a live
thread by offset (`worker_layout.Thread`), and an `@offsetOf` test guards it.

`startSearching` and `clearWorker` submit jobs to the runtime. The worker lifecycle
those jobs drive is covered in [04-multithreading.md](04-multithreading.md).

### The pool and the worker lifecycle

`thread_pool.zig` owns the `worker_layout.ThreadPool` footprint, `thread.reconfigure`
is the sizing path, and `thread.startThinking` dispatches a search across the pool.
Those, the `worker_build` / `worker_clear` / `worker_destroy` lifecycle hooks, and
what the workers share are covered in [04-multithreading.md](04-multithreading.md).

## Memory

`memory.zig` is the aligned / huge-page allocator, written with no `@cImport` — the
C entry points are declared directly, since `sys/mman.h` does not exist on Windows
and the macOS SDK headers do not cross-compile. `stdAlignedAlloc` is
`posix_memalign` on Linux/macOS and `_aligned_malloc` on Windows (whose blocks must
be released with `_aligned_free`, never plain `free`).

`alignedLargePagesAlloc` rounds the request up to a 2 MiB multiple, allocates it
2 MiB-aligned, **zeroes it**, and on Linux hints transparent huge pages via
`madvise(MADV_HUGEPAGE)`. macOS and Windows have no equivalent advisory call; the
alignment alone lets the OS back the block with large pages.

The engine never calls this directly — that would stop it being a standalone
library. It declares the `page_alloc` seam (`src/engine/state/page_alloc.zig`) for
its big long-lived arenas (transposition table, shared-history stats, NNUE storage),
and the composition root registers the platform allocator over it at startup. The
seam's default is a real page-backed allocator honouring the same contract, so a
headless engine build allocates correctly and loses only the huge pages.

## NUMA

`numa.zig` is the topology surface, and it delegates: every function resolves the erased
`numa_context` to the `NumaReplicationContext` that owns the `NumaConfig` and asks it.
`suggestsBindingThreads` evaluates the real rule, `configNodeCount` and `contextCpusInNode`
report the config's node count and per-node CPU count, `distributeThreadsAmongNodes` calls
`NumaConfig.distributeThreads`, and `contextSetSystem`/`Hardware`/`None` plus `setFromString`
install a new topology through `setNumaConfig` (which re-notifies replicated objects).
`setFromString` returns whether the string parsed: an unparseable `NumaPolicy` is refused and
the previous config stays live, matching upstream. `executeOnNode` runs the callback inline.
`configString` renders the process's `sched_getaffinity` mask as comma-joined CPU ranges on
Linux; elsewhere it reports the full range.

`numa/config.zig` is the model it drives. `NumaConfig` is a list of nodes, each an ascending
unique CPU set, plus a CPU→node index and the `custom_affinity` flag. `fromString` parses the
user `NumaPolicy` syntax (`"0-3,8:4-7"`), forces binding, and rejects a CPU claimed by two
nodes. `distributeThreads` balances threads across nodes by fill ratio.
`suggestsBindingThreads` mirrors upstream: bind on user-set affinity; never for a single
thread; otherwise bind when the thread count exceeds half the largest node **or** reaches
four per not-small node (a node holding ≤60% of the largest is ignored as small) — **and only
when there is more than one node**.

**The one real limit: `fromSystem` does not read the host topology.** It enumerates every
online CPU onto a single node, so on this machine `system` and `hardware` cannot differ. The
gap is topology *discovery* (`/sys/devices/system/node`), not the wiring above.

`numa/replication.zig` is the replica registry. `NumaReplicationContext` owns a
`NumaConfig` and tracks `NumaReplicatedBase` hooks — a plain function pointer
embedded in each replicated wrapper, no vtable. `setNumaConfig` swaps the config and
notifies every tracked object to re-replicate. The registry is exercised by the typed
`src/shell/engine/graph.zig` model and its unit tests. `EngineObject` owns the live
`NumaReplicationContext`: `constructMembers` builds one over `NumaConfig.fromSystem`, and the
teardown `deinit`s and frees it. See [04-multithreading.md](04-multithreading.md).

## Tablebases

`tablebase.zig` and `syzygy/` hold the Syzygy prober: discovery and cardinality, the
lazy table load, and the WDL/DTZ probe path. The engine reaches it through the
`tb_source` seam. The whole vertical — the tables, the probe path, root and in-search
probing, and the UCI options that gate it — is covered in
[05-tablebases.md](05-tablebases.md).

## The clock

`clock.zig` returns monotonic time in milliseconds: `QueryPerformanceCounter` /
`QueryPerformanceFrequency` on Windows, `clock_gettime(MONOTONIC)` elsewhere. It
feeds time management and the skill-level RNG seed.

Reading an OS clock is a syscall, so the engine cannot do it and stay portable. It
declares `src/engine/search/time_source.zig` — `pub var now: *const fn () i64` —
and the composition root points it at `clock.now`. The default is a per-call
monotonic counter: a valid clock in the wrong unit, which keeps a headless build
deterministic and is read by no time-limited root.

`libc.zig` is the companion: the entry points the code calls (`malloc`, `free`,
`exit`), declared directly as `extern "c"`. Stdio is
deliberately excluded — file reads, stdout/stderr writes, the stdin loop, the cwd
lookup, and every numeric format go through `std.Io` / `std.fmt`.

## runtime_hooks.zig

`runtime_hooks.zig` is the **lifecycle** hook registry: worker build, destroy, and
clear; the setup-state handoff; the shared-history clear/insert; and the thread-graph
verifier. The implementations live in the composition root because they need
`position` / `engine` / `network` / `search` — modules that already import their
callers (`thread`, `search_thread`, `thread_pool`), so the callers cannot import
back to reach them. The root installs the pointers at startup and the callers invoke
through here. See
[the composition root and the cycle-break hooks](00-architecture.md#the-composition-root-and-the-cycle-break-hooks).

The fields are non-optional, each defaulting to a named panic stub, so callers
invoke them directly with no null-unwrap and a hook that was never registered fails
fast **by name**. `zig build hook-lint` bounds the mechanism: it ratchets the hook
count and requires each hook to declare its failure mode when unregistered. Lifecycle
hooks are structurally safe — they cannot become per-query without the design
changing shape — unlike the service seams (`page_alloc`, `time_source`, `tb_source`),
whose `//! hook-class:` headers state the same contract from the engine side. See
[09-tooling-ci.md](09-tooling-ci.md) for the gate itself.

## Invariants

**`FUTEX_WAIT` takes the 4-argument form.** In `thread_runtime.zig` the Linux wait
must pass the timeout argument explicitly as null. `FUTEX_WAIT` reads that argument;
the 3-arg form leaves the register undefined, the kernel dereferences garbage and
returns `EFAULT`, the wait returns immediately, and the predicate loop busy-spins.
The engine still produces correct results, so no unit test catches it — only the
CPU burn shows.

**Large-page blocks are zero-filled.** `alignedLargePagesAlloc` `@memset`s the block
to 0. `posix_memalign` / `_aligned_malloc` return uninitialized memory; fresh OS
pages happen to be zero, but reused blocks (thread resize, search clear) carry stale
data, and a Worker field read during multipv search is initialized by neither the
constructor nor `clear()`. The zero-fill makes it deterministically 0. Worker
construction depends on this — do not remove it, and any allocator registered over
the `page_alloc` seam must honour it.

**`thread.zig` importing `option` is the one platform→shell edge.** `reconfigure`
reads the requested thread count and the NUMA policy mode straight from the shell's
option model. That single edge is the only thing keeping the zone graph from a
strict DAG; every other cross-zone need is met by a hook seam. See
[00-architecture.md](00-architecture.md).
