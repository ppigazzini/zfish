# E3 — the forward-declaration cut: execution plan (REPORT-11 E3, SUPERVISED)

De-risking worklist for the one RED→green cut. Open this + run `python3
zig_build/tools/frozen_refs.py zig_compat/uci_bridge.cpp -v` as the live checklist (drive it to 0).
Baseline at plan time (refactor `b5b9baae`): **28 live default frozen-type derefs**. Bench `2336177`
+ the E1 golden suite are the gate; `oracle-parity` is alive for one last cross-check before E4.

## TURNKEY EXECUTION (2026-06-28) — every fix, ready to apply

Apply in one focused push (RED until the end; revert if not green by session end so refactor stays
clean). All Worker/ThreadPool offsets exist in graph_layout (worker_off / thread_pool_off).

**Step A — includes (default branch only):** guard legacy-only these 7: engine.h, uci.h, thread.h,
search.h, position.h, score.h, perft.h. ADD (default) `#include "frozen_fwd.h"` + `#include
"timeman.h"` (timeman.h is clean — it forward-declares Search::LimitsType itself, giving
TimeManagement complete + LimitsType + fixes the TimeManagement::init/advance_nodes_time defs).

**Step B — frozen_fwd.h additions:** the Worker member-offset readers (mirror graph_layout):
```cpp
namespace zfish_wk {  // Worker member access by offset (Worker is forward-declared)
inline constexpr std::size_t kLimits=11419664, kRootPos=11419840, kManager=11422656,
                             kThreads=11422688, kTt=11422696;
inline char* base(void* w){ return reinterpret_cast<char*>(w); }
inline void* threads(void* w){ return *reinterpret_cast<void**>(base(w)+kThreads); } // ThreadPool*
inline void* tt(void* w){ return *reinterpret_cast<void**>(base(w)+kTt); }            // TT*
inline void* limits(void* w){ return base(w)+kLimits; }    // LimitsType* (value member)
inline void* root_pos(void* w){ return base(w)+kRootPos; } // Position*  (value member)
inline void* manager(void* w){ return *reinterpret_cast<void**>(base(w)+kManager); } // ISearchManager*
}
```
For nested ThreadPool members (w->threads.stop @793, .increaseDepth @794, .size() @799): use
thread_pool_off (stop@0, increaseDepth@1, threads-vec@16) on zfish_wk::threads(w) — there are already
native helpers zfish_threadpool_size / set_stop_flag etc.; prefer routing to those. For w->limits.X
(depth@84, mate@88, movestogo@80 etc.) use graph_layout.limits_off on zfish_wk::limits(w). For
w->main_manager() on the MAIN worker (the pv/setup path runs on it) use zfish_wk::manager(w), OR the
native main-manager nav on threads(w).

**Step C — the access sites (clean-file line numbers @541b8468):**
- 784-812 worker-setup / ZfishSearchTimeState builder: root_pos(784), threads.stop/increaseDepth
  (793-4), threads.size()(799), limits.depth/mate/use_time_management(800-2), main_manager()(812) ->
  zfish_wk + thread_pool_off/limits_off. (~10 sites — the bulk.)
- 853 zfish_search_id_pv: `zfish_search_pv(zfish_wk::manager(w), w, zfish_wk::threads(w),
  zfish_wk::tt(w), depth);`
- 1469-1471 tm.init path: `...tm.init(*(LimitsType*)zfish_wk::limits(w), ...)` — but tm is on the
  manager; route to the native time-init or read manager(w)->tm by offset. 1471 w->tt.new_search()
  -> native zfish_tt_* on zfish_wk::tt(w). NB this whole fn may be guard-able if the native search
  has its own init path — CHECK first.
- 1485/1497 ss_threads_start/wait: `zfish_threadpool_start_searching(zfish_wk::threads(w));` etc.
- 1505 ss_npmsec_advance: zfish_pool_nodes(zfish_wk::threads(w)) + limits via offset (this one is the
  deferred nodestime path — may stay legacy-guarded).

**Step D — static_asserts (700-704 + any sizeof(History/StateInfo/SharedHistories/PVMoves)):** wrap
the contiguous block `#ifdef ZFISH_LEGACY_CPP_TARGET ... #endif` (group D). The syzygy_extend_pv stub
@675 (takes Search::LimitsType&) is satisfied by timeman.h's LimitsType fwd-decl.

**Step E — iterate:** build, fix residual (the 20-error cap hides some; re-run until 0), then bench
2336177 + perft + eval-trace + misc + search-modes + valgrind + the oracle parities (last time).

REALITY: ~30-40 mechanical offset-substitution edits, concentrated in the worker-setup fn + ss_
bridges. Intricate (nested offsets) but bounded. A focused 1-session push; not 2-min-tick-sized.

## MEASURED CUT SCOPE (2026-06-28) — it is ~20-40 errors, NOT a full-src-surface big-bang

Test-dropped the 7 frozen-pulling headers in the default build (guard legacy-only + frozen_fwd.h) and
captured the real error set. KEY: the cut is SMALL + bounded because the include graph cooperates:
- Only 7 headers reference frozen types: engine.h/uci.h/thread.h/search.h/position.h (the frozen
  headers) + score.h (->position.h) + perft.h (->position/uci). DROP these 7.
- ALL other bridge headers are clean and STAY: types.h (Move/Square/Value/enums), movegen.h
  (already forward-declares Position! uses const Position&), bitboard.h, memory.h, misc.h,
  numa.h, tune.h, ucioption.h, evaluate.h, benchmark.h, shm.h, tt.h, movepick.h. So the feared
  "replace every src type" does NOT happen — the primitives come from the clean headers.

**The ~20 errors (clang caps at 20; a few more likely behind it), by category:**
- ~13 `member access into incomplete type Search::Worker` — the search-bridge pv/emit/glue reads
  Worker members directly (uci_bridge.cpp @880, 1512, 1524, 1532-1533, 1555, 1613, 1831, 1843, ...).
  CRUX: route each `w->member` to a native offset read (add graph_layout.worker_off entries) or
  guard the access legacy-only if it is dead in default. This is the bulk of the work.
- `SharedHistories` private member (`pawnHistSizeMinus1`) @702/731 — a sizeof/layout cross-check;
  guard legacy-only (group D) — it is in the static_assert region.
- missing forward-decls: `TimeManagement`, `Search::LimitsType`, `Search::PVMoves` — add to
  frozen_fwd.h. NB PVMoves is `ValueList<Move,N>` (template) — forward-decl as needed or the
  accessing code routes to offset; LimitsType/TimeManagement are plain forward-declarable.

So Step 1 is: drop the 7 headers + frozen_fwd.h (extended with TimeManagement/LimitsType), then work
the ~13 Worker member-access sites (offset-route or legacy-guard) + confine the SharedHistories
static_assert. Bounded + concrete — a focused 1-3 session push, RED-until-green, gate-verified by the
E1 suite + bench 2336177. NOT the catastrophic full-src rewrite. `refactor` stays green throughout.

## PROGRESS (autonomous Group A burndown COMPLETE): 30 -> 21 derefs

The route-to-native Group A items are done + merged (gate-verified by the E1 suite), shrinking the
cut surface from 30 to 21:
- perft root loop -> native do_move/undo_move; guard Position::do_move/undo_move (b5b9baae).
- Position::gives_check guarded — transitively dead once the position.h inline 2-arg do_move went
  uninstantiated (837b09d7).
- native flip route (zfish_engine_fen -> flip_fen -> set_position) -> guard Engine::flip /
  Position::flip / Position::fen (ed11ff86).
- Engine::get_default_network guarded — legacy-only construction (b336aec8).

**The remaining 21 are ALL cut-time (group B/C/D below) — confirmed by frozen_refs.py:**
Engine 8 (get_options ×2 [B], set_on_* ×5 [C], listener-install ×1 [B/C]), SearchManager 4
(UpdateContext [C]), UCIEngine 3 (move [the chess960-risky one], init/print [B]), Position 3
(set [B, header-inline], sizeof ×1 [D]), StateInfo 2 (sizeof/static_assert [D]), Thread 1
(wait_for_search_finished [B/E]). NB Position::set is group B not A — a src/ header inline keeps it
live (guarding it pre-cut fails to link), so it self-resolves at the include-drop. So Step 1 is now:
drop includes → B self-resolves, C stays as the opaque UpdateContext/std::function shim, D → the
graph_layout constants + legacy-confined static_asserts. NOTHING more is autonomously routable.

## The mechanism (why this is smaller than 28 edits)

Most derefs are method DEFS in uci_bridge.cpp that are kept live ONLY by `src/` header inlines which
call them. **Deleting the header deletes BOTH the declaration AND the inline caller**, so the def in
uci_bridge becomes uncallable → guard/delete it. Example, verified:
`src/uci.h:136  auto& engine_options() { return engine.get_options(); }` is the sole live caller of
`Engine::get_options()`; when uci.h goes, so does that call, so `Engine::get_options()` (3066/3069)
can be guarded legacy-only. So the cut is: (1) route the few derefs that have a NON-header caller to
native, (2) drop the includes, (3) mop up the now-uncallable defs.

## Step 0 — forward-decl header (additive, green)

Add `zig_compat/frozen_fwd.h`: `namespace Stockfish { class Engine; class UCIEngine; class
ThreadPool; class Position; class Thread; struct StateInfo; namespace Search { class Worker; class
SearchManager; struct SharedState; } }`. Provide named size constants from graph_layout for any
remaining `sizeof` (Position=1032, StateInfo=192). Do NOT include it yet.

## The 28 derefs, grouped by action

### A. Route to native, then the def is dead (NON-header callers) — do FIRST, each green
Native replacement EXISTS for every one (verified):

| deref | caller to reroute | native fn |
|---|---|---|
| `Position::fen` (3104) | perft fn, `d` already use `zfish_engine_fen` | `zfish_engine_fen` ✓ |
| `Position::gives_check` (3161) | search-glue caller | `zfish_position_gives_check_method` ✓ |
| `Position::flip` (3133) | `Engine::flip` (3075) | `zfish_position_flip_fen` ✓ |
| `Position::set` (3098/3141 + sizeof 3144) | perft local `p.set`, set_position | `zfish_position_set_state` ✓ |
| `UCIEngine::move` (3411) | perft divide `<<` | `formatMove` ✓ (verify chess960 string) |
| `UCIEngine::print_info_string` (3347) | option-change relay | native print (sync_cout shim) |
| `Engine::flip` (3075 + cast 3451) | `zfish_engine_flip_owner` | route to `zfish_position_flip_fen` on the native pos |
| `Engine::get_default_network` (2499) | engine construction | already native (`zfish_member_network_new` path); confirm dead, guard |

After each reroute: `frozen_refs.py` drops by 1, run `perft`/`misc`/`parity` (the E1 gates cover
exactly these paths). NB the perft `UCIEngine::move`→`formatMove` swap is the riskiest string-format
change — the **perft gate** (divide lines) is the precise check; expect to iterate.

### B. Self-resolve when the include drops (header-inline callers) — handled at Step 1
- `Engine::get_options` (3066/3069) — caller `uci.h:136 engine_options()`.
- `Engine::set_on_update_no_moves/full/iter/bestmove/verify_network` (2568-2584) + the install at
  `3280` + `UCIEngine::init_search_update_listeners` (3232) — the listener install path. These are
  the `std::function` emit (see C). The UCIEngine inlines that call them vanish with `uci.h`.

### C. The std::function emit (KEEP as a minimal forward-decl-compatible shim for the cut)
`SearchManager::UpdateContext` (2564/2565 accessor, 4186/4189 placement-construct) + the `set_on_*`
std::functions ARE live (the native search emit calls them to count nodes + print). DO NOT try to
remove them at the cut. Plan: the UpdateContext is already placement-constructed into a NativeEngine
inline byte-blob (`update_context_size=240`) via `zfish_member_update_context_construct`. Keep that;
forward-decl needs only that the blob is opaque bytes + the construct/destruct/accessor take `void*`.
Confirm those 4 sites use `void*`/byte-offset (they mostly do). The native-callback replacement that
removes `<functional>` entirely is **E5**, not the cut.

### D. sizeof / static_assert cross-checks → graph_layout constants, confine the asserts
- `sizeof(Position)`/`sizeof(StateInfo)` (3144) — replace with `graph_layout` constants in
  frozen_fwd.h once Position::set is routed (A).
- `static_assert(sizeof(StateInfo)==192)` (703) + the size cross-check cluster (700-704: SharedHistories/
  PawnHistory/PVMoves/etc.) — guard `#ifdef ZFISH_LEGACY_CPP_TARGET`. The legacy build keeps the
  compile-time check; default trusts graph_layout + bench; oracle-parity proves them equal one last
  time at E4.1.

### E. Thread::wait_for_search_finished (1990)
Referenced by the `~ThreadPool()` inline in thread.h (runs in neither build — the threads vector is
emptied first). When thread.h drops, the inline goes; guard the def legacy-only.

## Step 1 — drop the includes (the RED moment), iterate to green
Replace `#include "engine.h"/"uci.h"/"thread.h"/"search.h"/"position.h"/...` (default branch) with
`#include "frozen_fwd.h"`. Compile; resolve every error using A/B/C/D/E above. Loop until
`frozen_refs.py == 0` AND it links. Then: `bench` (2336177) → the full golden suite (`parity` minus
the dying `oracle-parity`, plus `perft`/`eval-trace`/`misc`) → `parity-valgrind` + `parity-teardown`
+ `parity-mt` + `parity-stress`. Human-review the forward-decl diff + the threading/numa touch points.

## Step 2 — exit to E4
One final `oracle-parity` + `output-parity` + `perft-parity` + `eval-trace-parity` + `misc-parity`
(last use of the oracle) to re-certify the goldens, then proceed to E4 (delete src/ + oracle + the
legacy husk; `h9` flips to green; wire `h9` into `parity`; tag `tu0`).

## Rollback
All on `mfinal-cutover`; `refactor` stays green. `git checkout refactor` abandons. Tag `pre-tu0-cut`
before Step 1.
