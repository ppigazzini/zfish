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

## Status
- [ ] native engine struct + offsets
- [ ] native construct (thread cluster native, giants interim side-alloc)
- [ ] native destruct
- [ ] accessor rewire
- [ ] bench green
- [ ] tail ports (network/numa/options/position/listeners)
- [ ] delete uci_bridge.cpp + src + oracle; H9 gate
