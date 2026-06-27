# Native engine cutover (M-FINAL) — branch `mfinal-cutover`

Goal: default-build C++ TU count → 0. Delete `zig_compat/uci_bridge.cpp` + `src/` +
the legacy oracle. Bench 2336177 bit-exact is the only end gate. RED-until-green on
this branch (user-approved); `refactor` stays green and untouched.

## The reframing (why this is NOT a 100-function all-or-nothing)

The bridge currently placement-constructs a C++ `UCIEngine`/`Engine` into the
Zig-allocated buffer (`zfish_uci_engine_construct_at`). All ~100 live bridge fns
operate on that C++ object's sub-objects *by reference*, and `~Engine`/`~ThreadPool`
free `states`/`threads`/`network` — that is the coupling that made it look atomic.

Replace the buffer's contents with a **native engine struct** (no C++ `~Engine` ever
runs) that *owns* each member as a side-allocation and frees them explicitly at a
native destruct. Then the coupling dissolves: each member becomes an independently
portable side-allocation, exactly like the already-done `tt`/`pos`/`sharedHists`.

### RED core (must flip together — the M-SM construction-crack on the thread cluster)
- native engine struct + its own `engine_off` offsets
- native `ThreadPool` (thread_runtime.zig) owned in/by the engine
- native `StateList` (state_list.zig) replacing `unique_ptr<deque<StateInfo>>`
- native worker construction (`zfish_native_worker_build`) reading native SharedState
- `setupStates` wiring: worker root state from native StateList, not `pool.setupStates->back()`
- native destruct: free threads/states/workers explicitly, bypass ~Engine/~ThreadPool/~Worker
- rewire the member accessors (deref pointer-members vs inline-offset)

### Incremental-green tail (port AFTER the flip, one side-allocation at a time)
- network storage (the 106MB NNUE giant) — interim: side-allocated C++ Network, freed explicitly
- numa context (NumaConfig::from_system topology) — interim C++ side-alloc
- options (OptionsMap registration) — native OptionsModel already the read authority
- position set/do_move (FEN parser + do_move for UCI setup) — interim C++ side-alloc
- listeners (`zfish_uci_set_listener_mode` std::function install) — native emit already authority
- the long mechanical tail of `zfish_network_*`, `zfish_numa_config_*`, `zfish_layer_*`, etc.

## Live C++ surface inventory (uci_bridge.o, default build) — ~100 C-ABI fns

Construct/destruct: uci_engine_construct_at, _destruct_at, _sizeof, _alignof,
  engine_construct_members (static).
Thread cluster (RED core): native_worker_build, native_worker_destroy,
  threadpool_setup_states_adopt_from_{slot,storage}, threadpool_has_setup_states,
  threadpool_setup_state_back, threadpool_bound_nodes_assign, threadpool_main_manager_ptr,
  threadpool_wait_thread, threadpool_zero_tt_slice, thread_ensure_network_replicated,
  engine_state_list_storage_{create,destroy,has_states,push,reset}, engine_states_slot_reset,
  search_shared_state_{create,destroy}, make_search_manager, search_id_pv, ss_emit_pv,
  ss_npmsec_advance, ss_threads_start, ss_wait_finished.
Network (tail): network_* (embedded_bytes, eval_file_content_hash, feature_transformer_*,
  hash_value, layer_*, mark_initialized, set_loaded_state, verify_info), worker_resolve_network,
  layer_{biases,weights}[_bytes], engine_evalfile_text, engine_syzygy_path_text.
Numa (tail): numa_context_set_{system,hardware,none}, numa_context_config,
  numa_config_{distribute_threads_among_nodes,execute_on_numa_node,suggests_binding_threads},
  engine_numa_set_from_string, engine_numa_config_{text,info_text}.
Position (tail): position_{create,destroy,set_state,do_move_state,move_is_legal}.
Options/owner (tail): engine_add_option, engine_apply_setoption_owner, engine_options_text_owner,
  engine_set_start_position, engine_flip_owner, engine_go_parsed_owner, engine_perft_owner,
  engine_tt_{resize,clear,hashfull}, engine_chess960_enabled, engine_emit_verify_message,
  engine_start_logger.
Misc/init: bitboards_init, now, operator_{new,delete}, graph_layout_size, uci_print_line,
  uci_set_listener_mode, movepick_fill_history_snapshot, root_move_sizeof,
  root_moves_{create_ranked,destroy}, limits_{sizeof,searchmoves_bytes,searchmove_text},
  shared_state_{clear_histories,insert_history,numa_policy_mode}.

## Validated design refinement (2026-06-26) — the flip is largely GREEN-able

Validation grep found ~30 bridge fns that cast `engine_ptr` to C++ `Engine*` and call
methods/members directly (`engine->get_options()["EvalFile"]`, `engine->numaContext.
get_numa_config().to_string()`, `engine->network.operator->()`, `engine->flip()`,
`engine->go/set_position/...`), and Workers hold direct refs `w->threads/network/tt`.
So a native engine struct is NOT transparent via the controllable accessors alone.

BUT it works as an **ownership container of heap-allocated members**:
- The native engine (Zig struct in the buffer) holds POINTERS to each member. Members
  stay INTERIM C++ heap objects (`new ThreadPool`, `new NumaReplicationContext`,
  `new LazyNumaReplicated(...)`, `StateListPtr(new deque<StateInfo>(1))`) for the flip;
  tt/pos/sharedHists/options-model/update_context are already native side-allocs.
- SharedState + Workers bind member ADDRESSES (they already take pointers/refs), so
  `w->threads.start_searching()` etc. are unchanged — a worker doesn't care whether
  `threads` is inline-in-Engine or a heap object bound by reference.
- The ~30 `static_cast<Engine*>(engine_ptr)->member.method()` call sites rewire to take
  the member pointer from the native engine and call the SAME C++ method on the heap
  object. Behavior-preserving → each is green-able.
- destruct: free each member explicitly (null the threads vector via native_threadpool_clear
  first, then `delete` the heap ThreadPool so ~ThreadPool frees setupStates; `delete` the
  heap numa/network; free native tt/pos/sharedHists). No C++ ~Engine/~UCIEngine runs.
- buffer sizeof shrinks from 1696 to the native struct (pointers + argc/argv for cli).

RED risk concentrates in the threads/setupStates/worker lifecycle + destruct ordering,
not in the 30 method rewrites. After the flip each interim-C++ member ports to native
one-at-a-time, incrementally green, until uci_bridge.cpp + src delete (TU=0).

## Status
- [x] heap-alloc bridge helpers (zfish_member_*) — 5a900e4a
- [x] native engine struct + offsets + construct/destruct — ec7272ad (green, unused)
- [x] PRE-FLIP green refactors — ccc0b804 + 2c3fe125: every direct C++ member-access site
      now routes through an accessor (get_options/flip/numaContext/network/the 4 set_on_*),
      so each returns &engine->member inline today and the heap/native member after the flip.
      bench 2336177 preserved. The flip is now isolated to alloc+construct+destruct+offsets.
- [x] THE FLIP — cd81852b. FULLY GATED GREEN on the first full-gate run: parity
      (oracle 2336177 / output 690 / search 51 / search-modes / golden) + test-graph +
      teardown (H5) + valgrind (H3, Threads {1,2}: no leak / bad access). The default
      build runs the NativeEngine container; no C++ ~Engine/~UCIEngine/~ThreadPool runs.
      The pre-flip accessor-routing made the RED flip land green immediately.
- [~] tail ports (network/numa/options/position/listeners) — each interim C++ member is an
      independently-owned side-allocation → ports INCREMENTALLY GREEN. Progress:
      - [x] position-set entry points — e70283ef + b6ea6121: Position::set (native FEN parser),
            Position::do_move (doMoveState), Position::legal → native (position.zig). Fully
            gated green. NOTE: this removed the C++ Position *method bodies* from those bridge
            ENTRY points, but the C++ Position *TYPE* is still threaded through many bridge
            signatures (Network::evaluate(const Position&), generate<>(const Position&),
            RootMove::extract_ponder_from_tt, syzygy_extend_pv, perft's local Position, the
            Position:: method shims at 2865-2920). Those methods are already native-shimmed;
            removing the TYPE means switching those signatures to void*/native — a larger grind.
      - [ ] REVISED SCOPE: the tail isn't "5 member ports" — it's removing pervasive C++ TYPE
            usage (Position/Network/OptionsMap/ThreadPool/NumaReplicationContext) threaded
            through the 4000-line bridge. Most leaf ops are already native-shimmed; the work is
            the glue + the type-parameterized eval/movegen/search C++ entry points. Mechanical
            but extensive. Candidates next: numa, options (model is read authority), then the
            big types. The flip (breakthrough) is done; this is the long mechanical grind.
- [ ] delete uci_bridge.cpp + src + oracle; H9 gate

### NETWORK type-removal plan + the MULTI-NODE caveat (2026-06-26, latest)
DONE (merged or on-branch): the C++ Network is runtime-vestigial (decouple steps 1-4) + the parse
byte-compare + serialization self-check cross-checks are retired (5 C++ fns gone). REMAINING to
delete the C++ Network TYPE: (a) drop the load-time content-hash check (the LAST load verification —
keep it; its removal is marginal + the type stays blocked regardless); (b) make the native parse
self-sufficient for SIZES (native layer/FT byte constants instead of zfish_layer_*_bytes — padding
makes these error-prone; derive + verify); (c) drop the C++ parse (zfish_network_*_read_blob); (d)
THE BLOCKER — the engine `network` member is LazyNumaReplicatedSystemWide<Network> (frozen src/numa.h),
numa-coupled. To delete the C++ Network type, this holder must become a NATIVE single-node holder.
That is SINGLE-NODE GATE-VERIFIABLE (the gate is single-node) BUT makes MULTI-NODE NUMA UNSUPPORTED —
a real limitation the single-node gate CANNOT detect. So removing the C++ Network type = a product
decision to drop multi-node numa support, not a pure refactor. Same caveat blocks the NUMA type
(NumaReplicationContext) — it's mutually coupled with the holder. CONCLUSION: the network RUNTIME
decoupling (the verifiable architectural win) is DONE + merged; the network/numa TYPE removal is a
large coordinated single-node-only effort gated on the multi-node-support decision.

### NETWORK reframing (2026-06-26) — the eval is ALREADY fully native; only load/holder remain
The "106MB giant" is mostly done. BOTH the feature transformer AND the affine layers are native-
stored (main.zig native_ft_ptr/native_ft_storage + native_layer_ptr/native_layer_storage), the
native parse (nnue_parse.zig parseFeatureTransformer/parseLayer/serializeLayer) writes weights
straight into that native storage, and the native eval (network.zig) reads ONLY native storage
(zfish_native_ft_ptr + zfish_native_layer_ptr). So the entire EVAL HOT PATH is native — the bulk of
the network's value. What remains C++ (uci_bridge): (1) the LOAD-TIME CROSS-CHECK — zfish_network_
feature_transformer_read_blob / layer_read_blob parse the .nnue into a C++ Network (via
NetworkBridgeAccess + read_parameters_blob) and zfish_*_content_hash / zfish_layer_biases/weights
compare it against the native parse to catch drift; (2) the HOLDER — LazyNumaReplicatedSystemWide<
Network> (the engine `network` member), numa-coupled, whose operator-> / [token] the workers resolve
(zfish_worker_resolve_network). NEXT: either drop the C++ cross-check (trust the native parse, gate-
verified) → the C++ Network parse fns go dead/legacy → then the holder is the last C++ network piece;
or keep the cross-check and port the holder. The cross-check removal is the higher-reward lever (kills
the most C++ Network usage). Map-first per the proven de-risk-then-wire template (states crack).

### NETWORK — post-eval-native blocking analysis (2026-06-26)
After the eval-layers-native port (5937ec61), the C++ Network's remaining default-build uses are:
(a) the LOAD-TIME CROSS-CHECK byte-compares (parseLayerNative @710-711 via zfish_layer_biases/
weights; parseFeatureTransformerNative @673 via zfish_network_feature_transformer_ptr) — these 3
data-accessor fns are now used ONLY by the compares; removing the compares makes them dead/guardable,
BUT the cross-check is a VALUABLE working safety net (it has caught real parse bugs) and the reward is
only ~3 fns, so NOT worth removing the net; (b) the C++ PARSE (zfish_network_*_read_blob into the C++
Network) — still needed for the layer/FT byte SIZES (zfish_layer_*_bytes, architecture constants
queried off the parsed Network) + offset advancement + the holder's Network content; (c) the HOLDER
(LazyNumaReplicatedSystemWide<Network>, the engine `network` member) — numa-coupled; the workers
resolve network through it. So the C++ Network can't be removed without (b→native sizes) AND (c→holder
port, which is numa-coupled). NET: the network is BLOCKED on the holder→numa coupling for further
removal. numa's multi-node paths are NOT gate-verifiable on single-node WSL2. The clean high-value,
gate-verifiable network work (eval fully native) is DONE.

### STATUS SUMMARY (2026-06-26): clean gate-verifiable ports largely exhausted
MERGED to refactor (all gate-verified, incl valgrind where teardown-relevant): native-engine flip,
Position set/do_move/legal, thread-cluster methods (zero_tt_slice/nodes_searched/tb_hits/main_manager/
has_setup_states), states deque->StateList crack. ON BRANCH (gate-verified): network eval fully native.
REMAINING = the hard tail, each blocked/intricate/risky-on-single-node: network (blocked on holder->
numa), numa (multi-node un-gate-verifiable), options (setoption works but callback_kind plumbing
unresolved — model registers kind=0 yet setoption Threads resizes, contradiction needs resolving
before a safe port), ThreadPool construction (low reward, bound-vec single-node-untested). TU=0 (delete
uci_bridge.cpp+src) needs ALL of these (the frozen src/ types are mutually-referential). This is the
"rest of the conversion" — a large effort, partly un-verifiable on this host; suits focused/supervised
work over autonomous loop ticks. The architectural CORE (native engine + native runtime: eval/search/
states/thread-methods/Position) is done + merged.

### DEFINITIVE remaining-work map (2026-06-26, after position ports)
The easy independent leaf ports are EXHAUSTED. Every remaining live default-build bridge fn
is coupled to a hard C++ subsystem/type (even zfish_uci_print_line shares the C++ sync_cout
output mutex). The ~90 live C-ABI fns group into these deep subsystems — each a LARGE
coordinated port (native type + rewire all its bridge fns + the woven signatures), not a
quick leaf:
  1. NETWORK (the giant): zfish_network_* (~13), zfish_layer_* (~4), worker_resolve_network,
     member_network_*, thread_ensure_network_replicated. Needs native ownership of the 106MB
     parsed Network (eval logic already native; STORAGE/parse is the giant). Coupled to numa
     (LazyNumaReplicated holds the NumaReplicationContext&).
  2. THREAD CLUSTER: zfish_threadpool_* (~8), zfish_engine_state_list_storage_* (~5),
     states_slot_reset, native_worker_build, search_shared_state_*, ss_* (~4). Native
     thread_runtime.ThreadPool + StateList EXIST. This is the original "RED core" but now
     tractable (engine is native). Highest-value next subsystem.
  3. NUMA: zfish_numa_context_* (~4), zfish_numa_config_* (~3), engine_numa_*. Native
     NumaConfig/NumaReplicationContext exist; coupled to network (#1).
  4. OPTIONS: add_option, apply_setoption_owner, options_text_owner, member_options_*. Native
     OptionsModel is the read authority; the C++ OptionsMap is the registration vehicle +
     info listener. Threaded into workers + syzygy.
  5. ENGINE-OWNER + MISC: go_parsed/flip/perft/start_logger/emit_verify/numa-text renderers;
     bitboards_init, operator_new/delete, uci_print_line, root_move_*, movepick snapshot,
     limits_searchmove_text, search_id_pv. Mostly thin but type-coupled or output-coupled.
HONEST SCOPE: the FLIP (breakthrough) is done + fully gated. TU=0 from here = these deep
subsystem ports (esp. NETWORK 106MB storage), a substantial multi-session grind. Recommend
merging the flip + position ports to refactor to lock in the breakthrough. Next subsystem:
the THREAD CLUSTER (#2) — native types exist, highest value, now decoupled by the flip.

### MERGED 2026-06-26: flip + position ports + zero_tt_slice leaf are on refactor (166d92b1+).

### THREAD-CLUSTER port plan (the construction-crack on ThreadPool) — investigated, de-risked
The C++ ThreadPool is woven and valgrind-sensitive; it is ONE coupled port, not small green
pieces. Key facts mapped:
- The frozen Worker (src/search.h) holds `ThreadPool& threads` at the C++ layout, so the pool
  buffer must stay sizeof(ThreadPool) with the C++ field offsets (thread_pool_off): stop@0,
  increaseDepth@1, setupStates@8 (StateListPtr = unique_ptr<deque<StateInfo>>), threads vec@16,
  boundThreadToNumaNode vec@40, main-manager via main_thread()->worker.
- The threads VECTOR is ALREADY native-managed by offset (native_threadpool.zig set/clear write
  begin/end/cap). boundThreadToNumaNode vec + setupStates deque are still C++.
- STATES lifecycle has TWO mechanisms: (a) ZfishPendingStateListStorage (a heap struct wrapping
  StateListPtr) built in the engine `states` slot via engine.zig ensurePendingStateStorage —
  used by setPositionEngine to build the root state chain (reset/push); (b) the raw deque from
  the flip's zfish_member_states_new in NativeEngine.states. setup_states_adopt moves the slot
  pointer into pool.setupStates@8; ~ThreadPool frees setupStates as delete(deque*). To go native
  StateList: the slot holds *StateList; adopt = pointer-move (StateListPtr is layout-compatible);
  CRITICAL: native destruct must free the StateList natively + NULL setupStates@8 BEFORE deleting
  the pool, else ~ThreadPool delete-as-deque* corrupts. Valgrind (Threads {1,2}) is the gate.
- ThreadPool METHODS still C++ (uci_bridge 1907-1955): main_manager/nodes_searched/tb_hits/clear/
  run_on_thread/wait_on_thread/num_threads. main_manager nav already ported native earlier; the
  rest are offset-iterations over workers (nodes_searched/tb_hits sum a Worker field) or native-
  routed (wait_on_thread). Port each to native offset-based, then the C++ method defs go legacy.
- CONSTRUCTION: zfish_member_threadpool_new = new ThreadPool() → raw operator-new(sizeof)+memset0
  (empty vectors/null setupStates = same as default ctor); destruct = native free of the three
  heaps (threads vec already via native_threadpool_clear; + bound vec + StateList) then free buf.
This is a focused multi-step RED-tolerant effort with valgrind verification at each step — NOT a
quick leaf. Best done as a dedicated push (the lifecycle/valgrind sensitivity rewards focus).

### STATES MECHANISM — fully mapped (2026-06-26), the de-risk for the StateList port
Three deques are in play, all of which must become native StateList together:
- SLOT = NativeEngine.states (a StateListPtr, currently the flip's member_states_new deque(1)).
  It is the FALLBACK root-state list. states_slot_reset resets it.
- STORAGE = a ZfishPendingStateListStorage (wraps a StateListPtr), mapped to the slot ADDRESS via
  a side-table (engine.zig pending_state_entries). setPosition builds the position's state chain
  here (storage_reset → root; storage_push per move). lookup/ensure/remove by slot_key.
- setupStates = ThreadPool@8 (StateListPtr). Gets EITHER deque at search start (thread.zig:859):
  handoffPendingStates → if storage has states, adopt_from_storage(pool, storage); ELSE
  adopt_from_slot(pool, slot). Then setup_state_back(pool) = setupStates->back() (the root).
LIFECYCLE (valgrind-critical, mirrors std::unique_ptr move):
- adopt_* does `pool.setupStates = std::move(src)` → MOVES the deque ptr, NULLS the source. So
  after adopt the storage/slot no longer owns it; setupStates does.
- releasePendingStateSlot → removePendingStateStorage + storage_destroy. If the storage was
  adopted (moved-out, now null) it frees nothing; else it frees the unused position chain.
- ~ThreadPool frees setupStates (the adopted deque). release runs BEFORE the pool delete.
NATIVE PORT (all-or-nothing): storage + slot hold a *StateList (state_list.zig: init/reset/push/
back/hasStates/deinit — exact match). A wrapper that adopt MOVES out + nulls preserves the move
semantics. CRITICAL ORDERING (native destruct): free the setupStates *StateList + null @8 BEFORE
deleting the heap ThreadPool (else ~ThreadPool delete-as-deque* corrupts the StateList). Every
adopt must free the prior setupStates *StateList (non-null between searches). state_info_size=192;
the block is opaque (Position fills it). Gate = valgrind Threads {1,2} (the only catch for a leak/
double-free). ~10 fns: storage_create/destroy/reset/push/has, states_slot_reset, adopt_from_storage/
slot, setup_state_back, release_pending_state_slot + the native_engine construct(slot)/destruct.

### CORRECTION (2026-06-26): updateContext is LIVE, not dead
The prior memory said updateContext was dead. WRONG. The native search emit calls
main_manager()->updates.onUpdateFull(...) / onBestmove / onUpdateNoMoves / onIter — the C++
std::functions — to record the node count (zfish_set_last_nodes_searched) and emit output.
The worker managers bind &updateContext via zfish_engine_update_context_ptr (engine.zig:518).
So NativeEngine.update_context MUST be a real placement-constructed C++ UpdateContext (helpers
zfish_member_update_context_construct/destruct added 2c3fe125), and set_on_* must write it via
the accessor (done). onVerifyNetwork (set_on_verify_network) is a separate engine member still
written inline — the flip needs a NativeEngine slot for it (or a native sink; check whether
verify_network() reads it or uses native emit).

### THREADPOOL forward-decl endgame map (2026-06-27, @ 9f657a11) — autonomous RED push begun
Accurate guard-checked audit (the python state-machine over-counts; use the awk depth-tracker):
the DEFAULT build's ONLY ThreadPool complete-type usages are exactly THREE:
  (1) inline helpers `zfish_pool_nodes/tbhits(const ThreadPool& t)` @1209-1210 — REFERENCE params,
      forward-decl suffices (a ref to an incomplete type is legal; `&t` → void* to the native fn).
      Reached in default ONLY via zfish_ss_npmsec_advance @1503 (the DEFERRED nodestime fn). The
      legacy pv/check_time callers (1229/1233/1342/1356/1406) are all legacy-guarded.
  (2) `zfish_threadpool_bound_nodes_assign` @3548-3559 — `static_cast<ThreadPool*>(pool_ptr)->
      boundThreadToNumaNode.clear()/.assign(...)`. NEEDS complete type (vector member access).
      THIS is the boundThreadToNumaNode vec — VALGRIND-SENSITIVE + UN-VERIFIABLE on single-node
      (the bound-vec is never populated on single-node WSL2, so the gate can't catch a bug here).
  (3) `sizeof(Stockfish::ThreadPool)` @4162 (the calloc) — needs complete type, BUT only matters at
      the FINAL include-removal step; converting it now (→ native size const) loses the compile-time
      safety for zero current gain while thread.h is still included.
ALL ThreadPool METHOD defs (main_manager/nodes_searched/tb_hits/clear/run_on_thread/wait_on_thread/
num_threads @2090-2143) are LEGACY-ONLY. CONCLUSION: ThreadPool forward-decl is blocked on (2) the
un-verifiable bound-vec port + (3) the final include-removal — NOT a clean autonomous win. This
matches the roadmap's "ThreadPool construction (low reward, bound-vec single-node-untested)".
REFRAME: TU=0's real grind is porting the ~180 default C++ bridge fns INTO Zig (then uci_bridge.cpp
has no default content → delete). Forward-decl is moot once a fn is in Zig (Zig already passes opaque
ptrs + reads frozen layouts via graph_layout offsets). NEXT-TARGET for the autonomous push: port the
most-tractable GATE-VERIFIABLE default bridge fns to Zig offset-access, cluster by cluster, skipping
the un-verifiable paths (bound-vec, numa multi-node). Avoid zfish_ss_npmsec_advance (nodestime hang).

### The flip's concrete edit set (next iteration) — now isolated (pre-flip refactors done)
- main.zig zfish_main: size buffer with zfish_native_engine_sizeof/alignof (was uci_engine_*).
- native_engine.zig constructMembers: also placement-construct update_context (call
  zfish_member_update_context_construct(&e.update_context)); add an onVerifyNetwork slot +
  construct it. destructMembers: destruct update_context + onVerifyNetwork before freeing.
- zfish_uci_engine_construct_at (uci_bridge): call zfish_native_engine_construct_members +
  zfish_engine_init_body(storage) + zfish_native_engine_set_cli + add_info_listener on the heap
  OptionsMap + init_search_update_listeners (sets the live updateContext) + Tune::init(heap opts),
  instead of placement-new C++ UCIEngine. zfish_engine_construct_members C++ retires (legacy-only).
- zfish_uci_engine_destruct_at: native_threadpool_clear + release_pending_state_slot +
  zfish_native_engine_destruct_members (no ~UCIEngine).
- main.zig accessors (the 6): numa_context/states/options/threads/network/update_context read
  NativeEngine.off fields, not engMember(engine, eng_off.*). cli argc/argv (2) → NativeEngine.off.
- add_option (uci_bridge): engine->get_options() already routes via the accessor (covered by
  ccc0b804) → no further change; it resolves the heap OptionsMap post-flip automatically.
- zfish_uci_engine_sizeof: already native-anchored (graph_layout.uci_engine_size); the buffer
  switches to zfish_native_engine_sizeof so the old constant is irrelevant on the live path.
- NOTE: init_search_update_listeners is a UCIEngine method (uci_bridge:2940). Post-flip there is
  no UCIEngine; call its body directly on the engine (set_on_* now go via the accessor, so it
  works) — or inline the equivalent engine.set_on_* calls in construct_at.
