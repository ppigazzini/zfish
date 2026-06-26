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
- [ ] THE FLIP (RED): wire main() alloc + zfish_uci_engine_construct_at/destruct_at +
      the 6 inline member accessors (numa/states/options/threads/network/update_context)
      + the 2 cli accessors to NativeEngine; route init_body through it. Drive bench green.
- [ ] tail ports (network/numa/options/position/listeners)
- [ ] delete uci_bridge.cpp + src + oracle; H9 gate

### The flip's concrete edit set (next iteration)
- main.zig zfish_main: size buffer with zfish_native_engine_sizeof/alignof (was uci_engine_*).
- zfish_uci_engine_construct_at (uci_bridge): call zfish_native_engine_construct_members +
  init_body(native_engine) + native_engine_set_cli + add_info_listener/init listeners + Tune::init,
  instead of placement-new C++ UCIEngine. zfish_engine_construct_members C++ retires (legacy-only).
- zfish_uci_engine_destruct_at: native_threadpool_clear + release_pending_state_slot +
  zfish_native_engine_destruct_members (no ~UCIEngine).
- main.zig accessors: numa_context/states/options/threads/network/update_context read the
  NativeEngine fields (NativeEngine.off) not engMember(engine, eng_off.*); cli argc/argv too.
- add_option (uci_bridge): use the heap OptionsMap pointer from the native engine, not
  static_cast<Engine*>->get_options().
- the ~30 static_cast<Engine*>(engine_ptr)->member.method() sites: take the member pointer
  from the native engine instead (rewire incrementally as bench failures surface them).
