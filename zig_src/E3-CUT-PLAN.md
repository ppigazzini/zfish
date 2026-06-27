# E3 — the forward-declaration cut: execution plan (REPORT-11 E3, SUPERVISED)

De-risking worklist for the one RED→green cut. Open this + run `python3
zig_build/tools/frozen_refs.py zig_compat/uci_bridge.cpp -v` as the live checklist (drive it to 0).
Baseline at plan time (refactor `b5b9baae`): **28 live default frozen-type derefs**. Bench `2336177`
+ the E1 golden suite are the gate; `oracle-parity` is alive for one last cross-check before E4.

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
