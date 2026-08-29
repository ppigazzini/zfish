# Upstream sync toolkit

Keeps the native Zig port in lock-step with the always-moving upstream Stockfish master: detect what
changed upstream, route each changed commit to the Zig file that must absorb it, and gate the result
bit-exact against a pristine upstream build.

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
| `upstream_golden_audit.sh [gate...]` | re-runs every golden's `<gate>` check with the ORACLE as the engine, so a reharden is PROVEN rather than self-blessed. `--list` prints the gate set. |
| `upstream_nodes.sh <sha> [depth] [fen...]` | node-count + bestmove localizer: our build vs oracle@`<sha>` at `go depth`. Bisect `<sha>` to find which commit first diverges when several search commits land together. |
| `upstream_net.sh [sha]` | ensures the target commit's `.nnue` (gitignored, per-worktree) is present in every worktree's `src/`. Run after a net bump so the merged `refactor` actually runs. |

## Steady-state workflow
```
# FIRST, before anything else: advance UPSTREAM_TARGET. The router classifies BASE..TARGET,
# so while TARGET still equals BASE it reports "0 of 0 commits need action" no matter how
# far behind the port is -- a clean bill of health that means only that nobody moved the pin.
git fetch upstream master && git rev-parse upstream/master > tools/upstream/UPSTREAM_TARGET

tools/upstream_sync.sh                    # fetch + worklist + bench targets (the whole TODO)
# for each WORKLIST commit (NNUE / bench / NET), oldest-first:
git show <sha> -- <owner src files>                 # the diff; router already named the .zig owner
#   ...port into the .zig owner. FORMULA commits: check C++/Zig integer semantics (see below).
zig build signature -Darch=x86-64-sse41-popcnt      # must equal <sha>'s Bench (from upstream_benchmap.sh)
# net bump?  cp the new .nnue + bump default_eval_file_name (engine.zig + network.zig), then upstream_net.sh
# stuck on a multi-commit gap?  upstream_nodes.sh <sha> to localize which position/commit diverges
tools/upstream_parity.sh                  # whole-engine gate; expect OK at HEAD
# then reharden + merge. Do NOT regenerate blind: `parity` first, and for each RED golden
# drive the oracle and match its bytes (docs/10-tooling-ci.md, "a golden is a photograph of
# ourselves"). A resync moving the reference is a legitimate reason to regenerate; a red gate
# you want green is not.
zig build parity ; echo $?                          # the red set names what the sync moved
#   READ THE EXIT CODE, not the log. mt-sanity fails with "does not reproduce the golden"
#   and never prints MISMATCH, so grepping for MISMATCH walks straight past it.
ZFISH_GOLDEN_UPDATE_FROM_ZFISH=1 zig build output-golden-update eval-trace-update \
    search-parity-update search-modes-update parity-mt-update
#   ...plus whichever of bench-matrix / chess960 / driver-golden / mate / nodestime /
#   tb-search / export-net / uci-options -update the sync actually moved.
#   THE ENV VAR IS REQUIRED and it is not a formality: every -update REFUSES to write a
#   golden photographed from the engine under test. A resync is the one case where the
#   reference genuinely moved -- upstream_parity above has already proven this binary
#   bit-exact against the pristine oracle -- so saying so explicitly is the sanctioned
#   path, and the audit below is what turns "we wrote it" into "upstream agrees".
# LOCAL-ONLY GATES ARE NOT IN parity AND NOT IN CI -- they go stale SILENTLY. Run them by hand
# every sync, or nobody learns their golden aged until it reads as somebody's regression:
zig build tb-cursed                                 # needs the 5-man set in resources/syzygy5
zig build tb-cursed-update                          # only after the oracle agrees, at the SAME SyzygyPath
# THEN PROVE the reharden: every golden re-checked with the ORACLE as the engine. This is the
# mechanical form of "drive the oracle and match its bytes" -- a golden that only agrees with
# ourselves is a photograph of ourselves, bug and all.
tools/upstream_golden_audit.sh                      # expect "19 agree, 2 differ" (18 under
#   --skip tb-cursed, which is what a run without the 5-man set can reach); the two differ are
#   chess960 and tb-root, and "Divergences the audit reports" below is what owns them. Read
#   that list before treating either as a finding: a THIRD differing gate, or a differing ROW
#   the list does not name, is the finding.
zig build signature output-golden eval-trace perft misc parity-mt parity-valgrind parity-teardown  # all OK
# THE TWO GATES THAT READ THE UPSTREAM TREE. Neither is in `parity` (a plain checkout of
# origin does not carry the objects) and both are dispatched only by the WEEKLY lane, so a
# resync that skips them learns a week late, from a job nobody is watching. Run them here:
zig build upstream-map      # a port that cites a new upstream file DRIFTS this map, and the
#   router then routes the next sync around the owner it does not name. The 2edd935b resync
#   drifted two rows this way (misc.cpp -> os_path.zig, thread.cpp -> session.zig).
zig build authors-lint      # AUTHORS is upstream's file verbatim; porting the SOURCE half of
#   a commit that also touched it is how it fell fifteen names behind.
cp UPSTREAM_TARGET UPSTREAM_BASE ; git commit ; git merge --ff-only <branch> ; git tag -f synced-upstream-<sha>
```

## Divergences the audit reports

`upstream_golden_audit.sh` drives the pristine oracle against our goldens, so a gate pinning
behaviour where **zfish is deliberately more correct than upstream** reports DIFFERS forever.
Each row below is a shipped fix with its own commit and its own reproduction; the golden pins
zfish, and this table is what stops the next sync reading it as drift.

Every one is Zone-A — reached only by a MALFORMED or sloppy input, or by a non-default option —
so none of them costs the bit-exact bridge anything: `upstream-parity` is OK at 2497913 with all
three in place.

| gate / row | zfish vs upstream | owner | expires when |
|---|---|---|---|
| `chess960` `sloppy-castling opt-off` | 8 moves, `e1c1=false` vs upstream's 9 with `e1c1`. `legal` tests the castling ROOK's geometry instead of the UCI_Chess960 option, so a `Q` token over a rook on b1 no longer generates a castle that leaves the king capturable. | `8100d0ce` | upstream adopts it and the row AGREES |
| `chess960` `dup-castling-token 1` | `... b B - 1 1` vs upstream's `... b - - 1 1`. Two tokens on one side resolve to one CastlingRights, and moving the DISCARDED rook no longer clears the surviving rook's right. | `cee6facd` | as above |
| `tb-root` `wdl-only-rule50-off` | 156 nodes vs upstream's 192. `rankRootMovesWdl` takes Syzygy50MoveRule for its draw test the way `rankRootMovesDtz` already did, so a won position with the halfmove clock past 99 is no longer ranked a draw with the tables switched off under it. | `f329737a` | as above |

Each commit body carries the before/after transcript, so a row that stops matching its stated
numbers is a REGRESSION in that fix, not an upstream move.

## The oracle
- **Pristine** (`upstream_oracle.sh`): vanilla upstream at any sha; the source of truth for `upstream_parity`
  and `upstream_nodes`. This is how we *follow* upstream, and it is now the **only** oracle.
- The former **in-tree legacy** oracle (`stockfish-legacy-cpp`, the `*-parity` gates) is **retired**:
  it shared this fork's ported Zig hot-path, so it was a self-consistency check rather than a true
  vs-upstream check, and it carried the whole vendored-C++ / `zig_compat/` build. The pristine worktree
  oracle is a strict superset (real upstream, drift-proof, cached no-op in steady state), so it replaces it.

## What each *No functional change* commit did here

`UPSTREAM_BASE` says the port is bit-exact at that sha — it does not say every upstream
commit has a Zig counterpart. A commit marked *No functional change* can be skipped
without moving a single node, which is exactly what makes it easy to skip by accident, so
record what happened to each one rather than leave the next reader to re-derive it from
the log.

**Nothing to port** — the whole diff is behind an ISA zfish has no backend for, or names a
construct zfish does not have:

| commit | why it is a no-op here |
|---|---|
| `43d4d0ef` Optimize RVV affine transforms | entirely inside `#if defined(USE_RVV)`, plus the RVV branch of `nnz_helper.h` and the RVV-only `dpbusd` macro. Its one non-RVV hunk moves `make_cursor` inside an existing `#if defined(VECTOR)` guard. No RVV backend. |
| `8e3b5b13` LSX/LASX NNUE paths | LoongArch SIMD. Its non-LoongArch half is the `UsePairedActivations` → `ScrambledInput` rename that belongs with `453f2207` below. |
| `23cf5d82` Remove Unused Option Constructor | deletes a C++ ctor overload (`Option::Option(const OptionsMap*)`). zfish's option model has no such constructor. |
| `fd3c762f` Improved Linux shared memory | rewrites `shm_linux.h` around `memfd_create` + Unix-socket fd passing. zfish implements no shared memory at all — nothing in `src/` mentions `memfd` or `shm_open` — so there is no counterpart to improve, only a subsystem to write. |
| `d077f9a8` BSD/macOS shared memory, `1ef7f2fe` UniqueFd, `4c37700c` memfd_create check, `762dd1da` SIGPIPE, `9dec2ead` registry simplification | the same missing subsystem as `fd3c762f`: five more commits over `shm_unix.h`/`shm_win.h` and their registry. Nothing here to port until zfish grows shared memory of its own. |
| `3647d524` Remove an incorrect AVX512 comment | deletes a comment about the last affine layer that was already false. zfish's `affineOut1` never carried it. |
| `881e0b45` Class Default Member Initializers for Option | moves `min`/`max`/`idx = 0` out of five C++ constructor initializer lists. zfish's option model has one `OptionsModel.add`, and every caller passes min/max, so there is no initializer list to shorten. |
| `358ab1bc` Cleanup FeatureTransformer Types | names the FT's region sizes and array types so `read_parameters`/`write_parameters` stop restating them. `nnue_dimensions.zig` already declares every count and offset once, and `nnue_parse`/`nnue_ft` read the SAME declarations to write and to read the blob — the property this commit buys, from a stronger direction. |
| `439733ea` Fix rm.exe "Permission denied" on Windows | a Makefile clean rule. zfish builds with `zig build`. |
| `1f711d49` Avoiding Redundant Calculations | hoists `from = to - D` out of `make_promotions`. `movegen.makePromotions` already computes `from` once (movegen.zig). |
| `5062aee5` Place continuation history on large pages | wraps `continuationHistory` in `make_unique_large_page`. `constructSharedHistories` already allocates `cont_data` through `page_alloc` (2 MiB-aligned, `MADV_HUGEPAGE`), same as the correction and pawn arenas. |
| `e37429bb` Simplify sliding_attack loop | folds the `dest` declaration into a C++ for-init so it stops outliving the outer loop. `bitboard.slidingAttack` already scopes `destination` inside, and walks with `lsb(destination)` where upstream walks with `s += d`. Nothing to fold. |
| `d68041e3` Read hash_bytes tail bytes as unsigned | `u64(end[i])` sign-extended, because `char` is signed on x86. `nnue_hash.hashBytes` takes a `[]const u8`, so the widen was never a sign-extension -- the defect is not representable once the accessor is typed ([09-type-design.md](../../docs/09-type-design.md)). |
| `92c90f41` Initialise time budgets on every path | already here: the no-clock return writes `timeman.no_bound` into both budgets rather than leaving the previous search's, which is the same fix (zfish b2b18cc3, upstreamed). |
| `30290aa0` Clamp speedtest inputs to valid ranges | already here (zfish 7f31c19c, upstreamed) with **one deliberate divergence**: the thread ceiling is `hardwareConcurrency`, not upstream's `MaxThreads` (`max(1024, 4*hw)`). A mistyped `speedtest 100000000` clamped UP to 1024 threads is a ~16 GB allocation, which is a worse outcome than the overflow the clamp removes; `benchmark.zig` states the reasoning where the bound is declared. |
| `49f8e667` Avoid UB decoding LEB128 | every part is already here, mostly by construction: `nnue_leb.decodeLeb` accumulates in `u32` (upstream's UB was `IntType result` shifted past its width), refuses a section that runs out of bytes (upstream's `buf_end == 0` failbit), and `nnue_parse.readLebSection` checks the magic and `used != count` where upstream had two asserts. The unbounded description read is bounded by `network_parse.readHeader` against the blob, which is what upstream's chunked read buys. |
| `50221673` Initialize shared continuation history once per NUMA node | closed by a different mechanism: `clearSharedHistory` STRIPES the fixed-size `cont_data` across the node's workers (`dynRange`) instead of having every worker fill all of it, so the redundant work upstream removes by electing thread 0 does not exist here. Same values, and the fill stays parallel. |
| `a3a8372b` More nnue_accumulator.cpp cleanup | unifies the vector / RVV / scalar copies of every accumulator kernel behind a `Tile` value type with `load_tile`/`store_tile`/`apply`. Zig's `@Vector` means there are no scalar and RVV copies to unify, and the shape it converges on -- tile the accumulator, hold the tile in a register, walk the row lists INSIDE, store once -- is already what `nnue_acc_rowops` does for the combined, hybrid, refresh-fused and psqt kernels (`b0ee1440` and the fused-kernel work that followed). |
| `ae3db60f` Align and collapse shared NNUE mappings | `shm_unix.h`. The same missing subsystem as `fd3c762f` above. |
| `229f6339` Update Release Creation | a GitHub Actions release workflow. |
| `bd85fb7f` Fix MSVC warning C4141 | moves `inline` into the `sf_always_inline` macro and drops it from every definition site, because `__forceinline` already implies it. Zig's `inline fn` is one keyword with one meaning; there is no pair of spellings to collide. |
| `53804033` Fix valgrind harness for expected-failure tests | upstream's `tests/instrumented.py` treated `--error-exitcode=42` as the expected non-zero exit of a failure-path test and so masked its leak report. `tools/valgrind.sh` runs no expected-failure case: every session must exit 0, `--error-exitcode=99` is the only non-zero it names, and any other non-zero fails the gate by itself. The masking is not expressible. |
| `7f73409c` Fix compile bug for Mac OS X 10.13.6 | `shm_unix.h` again -- `CMSG_SPACE()` is not a compile-time constant on some Unixes, so the message buffer becomes a vector. The same missing shared-memory subsystem as `fd3c762f` above. |
| `81d2cee9` Cache qemu-user deb & syzygy in CI | GitHub Actions cache keys in upstream's matetrack / sanitizers / universal-compilation workflows. zfish's lanes fetch their own tablebases through `tools/fetch_tb.zig`. |
| `d945b4d9` Update Top CPU Contributors | a text file. |
| `5cae0fab` Handle MAP_FAILED | the bug the `7ab49b9b` row below already refused to inherit, fixed upstream: `mmap_huge_aligned`'s `MAP_FAILED` is turned into a null before the `madvise` and the registry insert, and the non-large-page branch stops calling `madvise` on a failed allocation. `mmapHugeAligned` returns `?[]u8` (`catch null`) and every `madvise`/registry step already sits inside `if (mem) |ptr|`, so neither half is representable here. Its `tbprobe.cpp` half moves `madvise(MADV_RANDOM)` after the `MAP_FAILED` test; `table_load.loadFile` reads the table with `open`/`read` into an arena buffer and maps nothing, so there is no advice to reorder. |
| `074b1eac` Clean-up comments | 249 lines of upstream's own search.cpp prose rewrapped, plus a trailing space in `tests/instrumented.py`. zfish's search comments are written here, in imperative mood ([12-writing.md](../../docs/12-writing.md)), so upstream's rewrapping has nothing to land on. Its two SUBSTANTIVE additions did: the reason step 6 tests the TT value on every path (a probe races a concurrent write) is now on `search_main`'s Step 6, and the do-not-tune warning on the futility depth condition is now on `search.futilityDepth`. Everything else it adds -- that the mated-in rollback distrusts an aborted exact loss, that `prefetch_key` does not model castling -- zfish already says at the same sites. |

The parts of `22dfb404` (*miscellaneous cleanups*) that did not need porting: `nodes[n].size() == 0`
-> `empty()` and `threads.size() == 0` -> `empty()` name a C++ container idiom Zig has no
second spelling for, and `upcoming_repetition`'s `int j` scoping -- pulling the declaration
into the `if` so it stops outliving the loop -- is what `repetition.upcomingRepetition` already
does with `var j = h1(move_key)` inside its own iteration. The `O_CLOEXEC`, the `is_inexact`
rename and the step renumbering from that commit ARE ported, below.

**Ported** — the real changes in these ranges. Skipping these silently is how a port
stops being a port:

| commit | what landed |
|---|---|
| `db98633b` | `updateHybrid` (nnue_acc_entry.zig) -- a king move that stays on its half keeps the whole threat/pair accumulation, so only the HalfKA bucket swaps, both buckets coming from the refresh cache. Bounded by `MIN_PC_COUNT_HYBRID = 15`; castling excluded. |
| `7b550409` | `applyCombinedBoth` (nnue_acc_both.zig) -- when neither perspective needs a refresh, catch the lagging one up and walk the common suffix once, decoding each ply's diff a single time. |
| `453f2207` | `sqrClipPair512` (nnue_activations.zig) plus the flag split it introduced -- since superseded by `b52f0147` below, which made every AVX2-or-better tier scramble. |
| `c85637b3` | the quiet futility value loses `39 + 127 * !bestMove` for a flat `164` (search.quietFutilityValue); the dead `no_best_move` parameter goes with it. Bench 2829394. |
| `b0ee1440` | `tileRows`/`psqtRows` (nnue_acc_rowops.zig) -- the sign-and-weight-type-comptime row appliers upstream's three `always_inline` helpers are, with the combined, hybrid and refresh-fused kernels routed through them instead of carrying their own copies of the loop. |
| `b52f0147` | AVX-512 narrows with one `vpackssdw` (`packssdw512`) instead of two `vpmovsdw` + insert, so it now scrambles too: `pairScrambledChunk` holds both maps as one formula over the lane count (four lanes at 512, two at 256), `scrambled_activations == pair_activations`, and AVXVNNI joins the paired kernel. |
| `4150d22b` | `doMoveAcc` prefetches the child's two continuation-correction entries through `history.contCorrIndex`, the same derivation `setContHist` pages with. |
| `de948f0f` | the eval blend drops material from the optimism weight: `(nnue * (91000 + material) + optimism * 7675) / 91000`. Bench 2119477. |
| `fa8b6add` | `search.futilityDepth` -- step 8's cutoff steps 19 down to 13 through a six-threshold LUT as `abs(eval) + abs(beta)` grows, so mating lines stay searched. Bench 2884956. |
| `f21610e5` | the default net becomes `nn-1a298aa575a0.nnue` (AdamW-trained). Name only -- same architecture, so the parser, the feature transformer and the hash are untouched. Bench 2522345. |
| `5f7348f0` | `search.lmrLooseAlphaReduction` -- a quiet move in a loose alpha window reduces by `3 * clamp(alpha - eval, -64, 96)` more. The `eval` is the TT-refined one, not `ss.static_eval`, so `runBack` takes it as a node field. Bench 2132401. |
| `6d215a03` | `search.razorMargin` folds to `482 * depth * depth`. Bench 2516158. |
| `0c8c71f3` | `nnue_accumulator.transformPerspective` -- the per-perspective half of the transform, taking an accumulator half and an OUTPUT position rather than a side to move. |
| `68f7925d` | `fullAppendActive`'s two pawn directions become four explicit calls ahead of an absolute-colour piece loop; the helper takes the direction instead of branching on the colour. |
| `ee515ad9` | `RootPVMoves` (root_move.zig) -- the root's own growable, owning PV carrier, so a tablebase mate walk is bounded by mate, a draw or the clock rather than by the buffer. `PVMoves.assignTruncated` is where the two carriers meet, and `RootMove` drops from 1056 bytes to 96. |
| `ceb059eb` | `timeman.init` scales `limits.movetime` by `npmsec` under `nodestime`, beside the clock and the increment, so `go movetime N` stops after N milliseconds' worth of nodes rather than after N of them. |
| `7c37212e` | the three weight-storage allocation sites name the byte count and exit(1) instead of `@panic` -- upstream's `report_failed_allocation` shape, and the shape this tree wants for a diagnosable refusal. |
| `1b1b5f49` | `updatePieceThreats` takes its direct-threat set from the two ray sets `bothAttacks` already answered instead of re-sliding, and drops the redundant `& occupiedNoK` first pass. |
| `5fd94536` | three Syzygy refusals the loader lacked: a cyclic btree (three-colour DFS), a non-canonical Huffman code, and a header whose Split/HasPawns bits disagree with the registry. **Deliberate divergence:** upstream now `exit(EXIT_FAILURE)`s on a corrupt table; zfish refuses the table and keeps playing, which is what `parity-malformed` gates. |
| `3512dea6` | the diagnostic half of upstream's `pthread_create` check. Zig's `std.Thread.spawn` already returns a failed spawn and `thread_pool.set` propagates it, so the hang upstream fixes is not representable; what was missing is that every error in the resize chain arrived at one `@panic("OOM: thread pool resize failed")`. `SearchThread.spawn` now labels a failed start `error.ThreadSpawnFailed` and `resizeThreadsEngine` names which failure happened and exits 1. |
| `22dfb404` | the vocabulary: `RootMove.inexact_lower` / `.inexact_upper` / `.isInexact()` / `.isExactLoss()` / `.unsetInexact()` (plus the reporter's mutual-exclusion assert), `O_CLOEXEC` on the Syzygy table open, and a node's step numbers renumbered to upstream's new 1-24. |
| `7d9276c6` | `os_path.toWtf8Alloc` (a new `src/platform/` module) -- a path that fails WTF-8 validation is re-read through `MultiByteToWideChar(CP_ACP)`, so an old Windows GUI's ANSI path stops being refused with `error.BadPathName` before any file is opened. `option_model.normalize` is the single caller: every string option here is a path and the model owns the storage. The ANSI branch is compile-verified only. |
| `598ae2c4` | `search.seekMate(root_depth, root_moves[pv_idx].score)` -- true at root depth >= 16 with the line scoring past 2000. Step 9's futility cutoff becomes 6 instead of 19 while it holds, and Step 16's singular extension stands down. `search.futilityDepth`'s six-threshold LUT (fa8b6add) goes with it. Bench 2502027. |
| `19a02f44` | the tablebase PV extension's deadline: OFF under `nodestime` (its doMove calls never reach the global node counter, so aborting on wall time only made the reported PV nondeterministic), and the half-`Move Overhead` budget DIVIDED by MultiPV so N reported lines together stay inside the one budget a single line had. `>` becomes `>=`, and a budget already spent refuses before doing any work. |
| `7ab49b9b` | `alignedLargePagesAlloc` goes straight to `mmap` on Linux instead of `posix_memalign`, because a glibc arena outlives the thread it was created for and a later thread on another NUMA node reuses it. `mmapHugeAligned` over-reserves by one alignment PROT_NONE and MAP_FIXEDs the real mapping onto the aligned base; a mutex-guarded base -> length registry is what `munmap` needs, and `liveLargePageBlocks()` restores the leak coverage memcheck loses when a block stops being a malloc. **A divergence that upstream has since closed:** upstream's `mmap_huge_aligned` returned its final fallback `mmap` straight to a caller that tests `if (mem)`, so `MAP_FAILED` -- `(void*)-1`, not null -- registered as a live pointer and the next write to it segfaulted. Zig's `std.posix.mmap` returns an error for `MAP_FAILED`, so `catch null` here was a real refusal and the port could not inherit it. A sibling found this by watching its own allocation-refusal golden start crashing the oracle; upstream `5cae0fab` now nulls it the same way, so the two agree again. |
| `2edd935b` | the optimism blend adds the net term OUTSIDE the division: `nnue + (nnue * material + optimism * 7675) / 91000`. The same rational number and a different integer -- the truncation now runs over a numerator smaller by `91000 * nnue`. Bench 2497913. |
| `d96c183f` | the HalfKA changed/active index lists narrow to u16 (`nnue_acc_layout.PsqIndex`), which is what upstream's `write_indices` needed to store its 32 index words with one unmasked 512-bit store per list instead of widening each half to u32 first -- `nnue_feature_write_avx512` drops the two `_mm512_cvtepu16_epi32` pairs and the second pair of stores. `tileRows`/`psqtRows` take the list element type as a comptime parameter, the axis upstream's `apply_psqt` already templates on; the threat and pawn-pair lists still carry u32 here. A comptime bound beside `psq_feature_dimensions` (22528) is what keeps the narrowing lossless. |
| `8bc5caa2` | `tileRowsIncremental` (nnue_acc_rowops.zig) -- upstream's `apply_psq_features<sign, Incremental>`. A single ply's HalfKA list is one or two rows in each direction, so `applyCombinedDelta` peels the first apply out of the counted loop and predicates the second. `tileRow` is the shared single-row body (upstream's `apply<sign>`); the threat and pawn-pair lists, which are unbounded, keep the loop. The precondition is upstream's own assert, and it holds for the same reason: a null move pushes no accumulator state. |

**They pay, and that is a separate measurement.** Ablating the hybrid step and the shared
walk together (both routes off, same node count, so one tree with two amounts of work)
costs instructions 1.005 at avx2 and 1.017 at vnni512 -- so the two ports are worth
1.7% of whole-process instructions at the top tier, and more in the search alone.
docs/03-engine-eval.md carries the table. The sibling port measured the same pair
independently at 0.981 against zfish's 0.983.

**A bit-exact bench does NOT prove one of these ran.** Every accumulator route produces
the same values by construction, so a route that never fires is answered correctly by its
fallback and the anchor, the goldens, arch-determinism and the node differential all stay
green. `nnue_acc_update.PathCounts` (compiled in under `builtin.is_test` alone) is what
closes that, and `headless_search.zig` asserts every route moved. Do the same for the next
one: land it, then prove it fires, then mutate it and watch the right gate go red.

## Integer-semantics watch (FORMULA commits)
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
