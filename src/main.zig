const std = @import("std");
const c = @import("libc");

const engine_port = @import("engine");
const memory_port = @import("memory");
const uci_output = @import("uci_output");
const graph_layout = @import("graph_layout");
const native_hooks = @import("native_hooks");
const clock = @import("clock");
const worker_construct = @import("worker_construct.zig");
const thread_construct = @import("thread_construct.zig");
const worker_native_construct = @import("worker_native_construct.zig");
const native_engine = @import("native_engine"); // native engine container
const misc_port = @import("misc");
const nnue_accumulator_port = @import("nnue_accumulator");
const network_port = @import("network");
const state_list_port = @import("state_list"); // native `states` member
const nnue_feature_port = @import("nnue_feature");
const option_port = @import("option");
const position_port = @import("position");
const search_port = @import("search");
const thread_port = @import("thread");
const timeman_port = @import("timeman");
const uci_port = @import("uci");
const position_snapshot = @import("position_snapshot");

comptime {
    _ = graph_layout;
    _ = worker_construct;
    _ = thread_construct;
    _ = worker_native_construct;
}


pub fn main(init: std.process.Init) !void {
    // Cross-platform argv (M-PORT): initAllocator handles Windows/WASI, where argv must be
    // decoded from the raw command line into an owned buffer (on POSIX it is a no-op view of
    // the kernel-provided vector). The iterator owns the arg strings, so it stays alive
    // (deinit deferred) for all of main -- argv points into its buffer. Collected once into a
    // C-style [*:0]u8 vector for the engine constructor.
    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arg_iter.deinit();

    var argv_list = std.ArrayList([*:0]u8).empty;
    defer argv_list.deinit(init.gpa);
    while (arg_iter.next()) |arg| {
        try argv_list.append(init.gpa, @constCast(arg.ptr));
    }
    const argv = argv_list.items;
    const argc = argv.len;

    const info = misc_port.engineInfoText(0) orelse return error.OutOfMemory;
    defer c.free(@ptrCast(info));

    _ = c.puts(@ptrCast(info));

    // The native movegen computes attacks/rays on the fly (bitboard.zig slidingAttack
    // etc.); the runtime tables come from position_port.initRuntime().
    position_port.initRuntime();
    installNativeHooks();

    // Zig-owned engine footprint: allocate aligned storage, placement-construct the
    // NativeEngine (an ownership container of heap members) into it, and on teardown
    // destruct-in-place then free (defers run LIFO, so destruct precedes free).
    const eng_align = native_engine.alignofEngine();
    const eng_size = native_engine.sizeofEngine();
    const engine = memory_port.stdAlignedAlloc(eng_align, eng_size) orelse
        return error.OutOfMemory;
    defer memory_port.stdAlignedFree(engine);

    nativeUciEngineConstructAt(engine, @intCast(argc), argv.ptr);
    defer freeSideTt(); // M1: free the side tt AFTER the engine destruct (LIFO)
    defer engine_port.freeSharedHistories(); // M-SH: free the side sharedHistories map (after destruct)
    defer uciEngineDestructAt(engine);

    uci_port.loopRuntime(engine);
}

// The native StateList backs the position-setup chain, the engine `states` slot
// (fallback root), and the pool's setupStates. PendingStateStorage carries move
// semantics (state_list.zig); the slot + setupStates hold a `?*StateList`, and
// adopt MOVEs the pointer + nulls the source.
const StateList = state_list_port.StateList;
const PendingStateStorage = state_list_port.PendingStateStorage;

fn poolSetupStatesSlot(pool: *anyopaque) *?*StateList {
    return @ptrCast(&graph_layout.ThreadPool.fromPtr(pool).setup_states);
}
fn freeSetupStatesIfAny(pool: *anyopaque) void {
    const slot = poolSetupStatesSlot(pool);
    if (slot.*) |old| {
        state_list_port.destroyStateList(std.heap.c_allocator, old);
        slot.* = null;
    }
}

// adopt: MOVE the StateList into the pool's setupStates, freeing any prior one
// (between searches setupStates still owns the previous list).
fn threadpoolSetupStatesAdoptFromStorage(pool: *anyopaque, storage: *anyopaque) void {
    freeSetupStatesIfAny(pool);
    poolSetupStatesSlot(pool).* = @as(*PendingStateStorage, @ptrCast(@alignCast(storage))).moveOut();
}
fn threadpoolSetupStatesAdoptFromSlot(pool: *anyopaque, slot_ptr: *anyopaque) void {
    freeSetupStatesIfAny(pool);
    const src: *?*StateList = @ptrCast(@alignCast(slot_ptr));
    poolSetupStatesSlot(pool).* = src.*;
    src.* = null;
}
fn threadpoolSetupStateBack(pool: *const anyopaque) ?*anyopaque {
    const slot: ?*StateList = @ptrCast(@alignCast(graph_layout.ThreadPool.fromPtr(@constCast(pool)).setup_states));
    if (slot) |list| return list.back();
    return null;
}

// Native Worker::clear: the per-search worker reset the clear_worker job runs on
// its thread. The four native clear helpers in declaration order: histories, the
// shared-history page (sharedHistory ref + numaThreadIdx@thread_idx+8 /
// numaTotal@+16), the reductions table (int[256], the 1024-byte slot before
// manager), and the refresh cache (native feature-transformer biases). All four
// callees are gate-verified; only this orchestration is new.
fn workerClearNative(worker: *anyopaque) void {
    const wb = @intFromPtr(worker);
    const off = graph_layout.worker_off;
    position_port.clearWorkerHistories(worker);
    const shared_history: *anyopaque = @ptrFromInt(@as(*const usize, @ptrFromInt(wb + graph_layout.worker_off.histories + position_port.worker_shared_history_off)).*);
    const numa_thread_idx = @as(*const usize, @ptrFromInt(wb + off.numa_thread_idx)).*;
    const numa_total = @as(*const usize, @ptrFromInt(wb + off.numa_total)).*;
    position_port.clearSharedHistory(shared_history, numa_thread_idx, numa_total);
    const reductions: [*]c_int = @ptrFromInt(wb + off.reductions);
    search_port.fillReductions(reductions, 256);
    const refresh: *anyopaque = @ptrFromInt(wb + off.refresh_table);
    const biases: [*]const i16 = @ptrCast(@alignCast(network_port.nativeFtPtr() orelse return));
    nnue_accumulator_port.clearRefreshCache(refresh, biases);
}

// operatorNew/operatorDelete: the matched alloc/free family for the native
// containers (RootMoves/searchmoves/bound_nodes/Position/caches). They bottom out
// in malloc/free, so any allocation here is freed by the matching free -- verified
// by parity-valgrind + parity-teardown.
fn operatorNew(n: usize) ?*anyopaque {
    return std.c.malloc(n);
}
fn operatorDelete(p: ?*anyopaque) void {
    std.c.free(p);
}

// LimitsType layout anchors + worker limits/root-moves setters relocated to thread.zig (M16.7).

// Worker limits readers: pure LimitsType offset reads — no allocation, so no
// allocator-boundary mismatch (the trap that blocks porting operator new/delete).
// Offsets from graph_layout.limits_off (verified vs the LimitsType field order).
// Worker set_limits: the `limits = value` copy of LimitsType. Copies only the POD
// tail (everything after the leading std::vector<std::string> searchmoves). The
// Worker's searchmoves copy is vestigial (the search filters root moves from the
// source limits at root setup, never from worker.limits), so it stays at the
// zeroed-empty state worker construction set -- valid for ~vector, no string-ABI
// deep copy, no leak. POD tail starts right after searchmoves.

// search quiet-move scales retired -- position.zig calls search directly (M16.5).

// conthist-delta: position.zig calls search.conthistDelta directly (M16.7).

// movegen capture/quiet/evasion generation: movepick.zig calls the movegen module
// directly (M16.7).


// thread start-thinking: engine calls thread.startThinking directly (M16.7).

fn pendingStatesAvailable(states_slot: *anyopaque) u8 {
    return engine_port.pendingStatesAvailable(states_slot);
}

fn handoffPendingStates(
    pool: *anyopaque,
    states_slot: *anyopaque,
) u8 {
    return engine_port.handoffPendingStates(pool, states_slot);
}

// threadpool reconfigure: engine calls thread.reconfigure directly (M16.7).




// Side-to-move of a Position by pointer. Reuses the native layout authority
// (position_port.sideToMove), so no offset needs pinning.
// Native SearchManager data-field shims. The main manager's data members are written
// through the manager pointer plus the search_manager_off offset map, so these resets
// use no SearchManager type.
// Native ThreadPool flag shims: stop and increaseDepth are the leading
// std::atomic_bool pair at pool+0 / pool+1. Written directly (single-threaded
// setup context).
// Native Thread->worker field reads. thread+8 holds the Worker pointer; read the
// relaxed-atomic u64 counters at the worker's nodes/tbHits offsets. Match
// Thread::worker_nodes_searched()/worker_tb_hits().
// ThreadPool::thread_at(i) == threads[i].get(): the i-th unique_ptr<Thread> in
// the threads vector is a single pointer, so .get() is the loaded slot value.
// begin() is the vector's begin pointer at threads_begin; element stride is the
// 8-byte unique_ptr.
// Mutable Thread -> Worker resolution (LargePagePtr<Worker> at Thread+8).
// Worker::reset_root_setup_state zeros the five per-search counters. They are POD
// (the two node counters are atomics, but a relaxed store of 0 is a plain zero
// write), so each is set through the worker offset map.

// The thread.zig TbConfig C-ABI struct passed by value:
// {int cardinality; u8 root_in_tb; u8 use_rule50; int probe_depth}.

// Worker::set_tb_config assigns worker.tbConfig = Tablebases::Config{...}. The
// Config is POD {int cardinality; bool rootInTB; bool useRule50; Depth(int)
// probeDepth} laid out as cardinality@0, rootInTB@4, useRule50@5, probeDepth@8.
// The two flags are normalized with `!= 0`, so booleans are written 0/1.
// Padding bytes (+6,+7) are never read by the search, so they are left alone.

// Worker::set_root_state assigns worker.rootState = value. StateInfo is fully POD
// (scalars plus one raw `previous` pointer), so a member-wise copy is a byte
// copy; the native version memcpy's the 192-byte StateInfo into the Worker
// rootState slot.

// Worker::set_root_position runs rootPos.set(fen, chess960, &rootState). Position
// set is already native (position_port.setPosition); the dispatcher resolves the
// in-Worker rootPos and rootState by offset and runs it, discarding the error string
// exactly as set_root_position discards the returned Position&.


// pool->main_manager() = main_thread()->worker->main_manager() as native offset
// navigation: thread[0] -> worker@thread_off.worker -> manager@worker_off.manager (the
// unique_ptr<ISearchManager>'s stored pointer == the SearchManager* for the main thread).

// Native-inert tablebase probe entry points. The Zig runtime ships no Syzygy
// tablebases (max cardinality 0 -> the native probe path short-circuits before ever
// probing), so these report "unavailable" and init is a no-op.




// The NumaPolicy setters are no-ops — the numa context is a fixed single-node native
// stub, so reconfiguring it does nothing (and must not touch the stub).
// Install the native runtime hooks (M16.9): these impls live here because they need
// position/engine/network/search/state modules that already import their callers
// (thread/engine/native_thread), so the callers reach them through the native_hooks
// fn-pointer registry.
fn installNativeHooks() void {
    native_hooks.shared_state_clear_histories = &sharedStateClearHistories;
    native_hooks.shared_state_insert_history = &sharedStateInsertHistory;
    native_hooks.native_worker_destroy = &nativeWorkerDestroy;
    native_hooks.native_worker_build = &nativeWorkerBuild;
    native_hooks.worker_clear = &workerClearNative;
    native_hooks.setup_states_adopt_from_storage = &threadpoolSetupStatesAdoptFromStorage;
    native_hooks.setup_states_adopt_from_slot = &threadpoolSetupStatesAdoptFromSlot;
    native_hooks.setup_state_back = &threadpoolSetupStateBack;
    native_hooks.pending_states_available = &pendingStatesAvailable;
    native_hooks.handoff_pending_states = &handoffPendingStates;
    native_hooks.verify_thread_graph = &thread_construct.verifyThreadGraph;
}

// The engine `pos` is a native side-allocated Position block. sizeof(Position)==1032;
// Position is POD-ish (its `st` points to the separate states list — no owned heap), so a
// zeroed block needs no teardown free, and init_body's pos.set(StartFEN) fills it through
// this accessor. The native position ops (position.zig) operate on it; setPosition /
// start_thinking / fen all reach it via this accessor. The engine buffer is a NativeEngine,
// so the member accessors return its fields (the heap member pointer for pointer-members;
// the field address for the inline states slot / update_context).
fn nativeEng(engine: *anyopaque) *native_engine.NativeEngine {
    return native_engine.NativeEngine.fromBuffer(engine);
}
// numa_context / update_context accessors are not needed here -- engine.zig reaches
// those slots through native_engine.zig accessors. threads_ptr is main-internal only.
fn engineThreadsPtr(engine: *anyopaque) *anyopaque {
    return nativeEng(engine).threads.?;
}
// The engine's tt is a native side-allocated TranspositionTable. The engine is a
// singleton, so a freed-and-rezeroed global suffices. Layout is the native TT
// (tt_off: cluster_count@0, table@8, generation@16); 64 bytes generously covers
// sizeof(TranspositionTable). init_body resizes it through this accessor. Native ops
// (resizeState/clearState/probe) operate via tt_off; sizing is the same native code the
// live search uses, so the side tt is bit-identical (bench gates it).

// Free the side tt's large-page table at engine teardown + rezero for any re-construct
// (H5/valgrind). The table pointer lives at tt_off.table within the side storage.
fn freeSideTt() void {
    const table_ptr: *?*anyopaque = &graph_layout.TranspositionTable.fromPtr(native_engine.sideTtPtr()).table;
    if (table_ptr.*) |tbl| memory_port.alignedLargePagesFree(tbl);
    native_engine.sideTtReset();
}
// The engine's native SharedHistoriesMap side storage + its clear/insert/at/free
// operations live in engine.zig (M16.7): the map is engine-owned, reached through the
// engine module (engine_port.sharedHistories*).
// SharedState create/destroy: engine.zig now calls shared_state.zig directly (M16.7).
// options-text: uci.zig calls option.render directly (M16.7).
// engine flip: uci.zig calls engine.flipEngine directly (M16.7).
// Set the start position via the native set-position machinery (StartFEN is a
// constexpr literal; the value is gate-verified by misc + bench, which start from this position).
// UCIEngine::engine is the first member (offset 0): the accessor is the identity.
// UCIEngine::engine is the first member (offset 0), so the accessor was the
// identity: uci.zig now uses the engine pointer directly (M16.7).

// Worker -> threads (ThreadPool&) and Worker -> manager (the worker's own
// SearchManager via the unique_ptr) resolvers. Both slots hold a pointer (the
// reference is stored as a pointer; main_manager() is manager.get()), so the
// resolver loads the slot value.
fn workerThreadsPool(worker: *const anyopaque) usize {
    const p: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.threads));
    return p.*;
}
fn workerManager(worker: *const anyopaque) usize {
    const p: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.manager));
    return p.*;
}

// worker->rootMoves[0]: rootMoves is a std::vector<RootMove> whose begin pointer
// is the first element's address.
fn workerRootMove0(worker: *const anyopaque) usize {
    const begin: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.root_moves));
    return begin.*;
}


// set-prev-scores: relocated into position.zig (M16.7).

fn workerTT(worker: *const anyopaque) usize {
    const p: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.tt));
    return p.*;
}

// pv-one-and-ponder: relocated into position.zig (M16.7).

// The native UCI output primitive (printLine) + log-file sink + portable cStdout
// moved into the uci_output leaf module (M16.7); main and engine call it directly.

// emit-verify-message relocated into engine.zig (M16.7).

// workerRefPtr: read a Worker reference slot -- threads/tt/manager are pointers stored at
// worker+offset, using graph_layout.worker_off (the same offsets the native search reads).
fn workerRefPtr(worker: *anyopaque, offset: usize) ?*anyopaque {
    const slot: *const ?*anyopaque = @ptrCast(@alignCast(@as([*]u8, @ptrCast(worker)) + offset));
    return slot.*;
}
// ss_threads_start / ss_wait_finished relocated into position.zig (M16.7): the driver
// drives the native thread pool directly (native_thread search job is a fn-pointer).
// emit_pv / search_id_pv PV-emit wrappers relocated into position.zig (M16.7).
// threadpool wait-thread: consumers call thread.waitThread directly (M16.7).
// SharedState.sharedHistories (a reference) is the 4th pointer field of the native
// SharedState struct (shared_state.zig: options/threads/tt/shared_histories/network), i.e.
// offset 24. Read that stored pointer directly and clear the native SharedHistoriesMap.
fn sharedStateClearHistories(shared_state: *const anyopaque) void {
    const shared_histories_off: usize = 3 * @sizeOf(usize);
    const slot: *const *anyopaque = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(shared_state)) + shared_histories_off));
    engine_port.sharedHistoriesClear(slot.*);
}
// insert_history: single-node default never binds (do_bind always 0, numa_config unused) — insert
// directly into the native SharedHistoriesMap reached via the offset-24 shared_histories pointer.
fn sharedStateInsertHistory(shared_state: *const anyopaque, numa_config: *const anyopaque, numa_index: usize, size: usize, do_bind: u8) void {
    _ = numa_config;
    _ = do_bind;
    const slot: *const *anyopaque = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(shared_state)) + 3 * @sizeOf(usize)));
    engine_port.sharedHistoriesInsert(slot.*, numa_index, size);
}
// With NNUE_EMBEDDING_OFF the embedded net is the 1-byte {0x0} stub; loadNetworkBytes
// fails on it and falls back to the on-disk EvalFile (bench validates the file net).
// set_loaded_state is a no-op: the native load owns the EvalFile state (nn_current/
// nn_description, set just before these calls), so there is nothing more to record.
fn networkSetLoadedState(network: *anyopaque, current_name_ptr: [*]const u8, current_name_len: usize, description_ptr: [*]const u8, description_len: usize) void {
    _ = network;
    _ = current_name_ptr;
    _ = current_name_len;
    _ = description_ptr;
    _ = description_len;
}
// uci listener/quiet mode: uci.zig calls uci_output.setQuietMode directly (M16.7).
// numa_set_from_string no-op stub moved into numa.zig (M16.7).
// ssNpmsecAdvance: relocated into position.zig (M16.7).
// The movepick history snapshot. Stats::data() returns the object's flat storage,
// which is the object's own address — so each history pointer IS its .data() (identity). The
// snapshot is just: copy the table pointers + the 6 continuation pointers + the shared-history
// pawn table/mask (SharedHistories pawnHistory@16 {size@0,data@8}, pawnHistSizeMinus1@40).
// Bench/movepick exercises this every node, so search-parity certifies the offsets.
// The read-blob fns are no-ops: weights are served from native storage, so the parse
// result is discarded.
fn networkLayerReadBlob(network: *anyopaque, bucket: usize, data_ptr: [*]const u8, data_len: usize) usize {
    _ = network;
    _ = bucket;
    _ = data_ptr;
    _ = data_len;
    return 0;
}
// Native engine teardown. Free the states slot, join+free the native Threads + null the
// pool's threads vector, then free the heap members. All three are native.
fn uciEngineDestructAt(storage: *anyopaque) void {
    releasePendingStateSlot(native_engine.NativeEngine.fromPtr(storage).statesSlotPtr());
    thread_port.nativeThreadpoolClear(engineThreadsPtr(storage));
    nativeEngineDestructMembers(storage);
}

// Allocate the UCI score text for a raw value: classify (VALUE_TB_WIN_IN_MAX_PLY=
// 31507, VALUE_TB=31753, VALUE_MATE=32000), then map to the cp/tb/mate formatter
// exactly as the Score classification visit. Caller frees via c_allocator.

// Windows steady clock (M-PORT): QueryPerformanceCounter is the monotonic high-res
// counter; ticks/QueryPerformanceFrequency gives seconds. Declared here (not in
// std.os.windows) and only referenced on the Windows branch of zfishNow.

// now(): Stockfish::now() = steady_clock ms; CLOCK_MONOTONIC is the POSIX steady_clock
// (QPC on Windows). now() is used only for elapsed-time (the goldens are fixed depth/
// nodes, so the absolute value isn't gated — only monotonicity). Ported across the owned
// OSes (M-PORT).

fn optInt(name: []const u8) c_int {
    return option_port.intByName(name);
}

// Option readers: read the native OptionsModel (option.zig) by name. The model is the
// write-authority — every option is registered at add and re-published on setoption — so
// reading it by name is the option's current value (bench gates Hash/Threads since they
// size the TT / thread pool). The `options`/`shared_state` pointer args are unused (the
// model is a process-global).
// String-option readers: duplicate the model's string value into a malloc'd C string the
// caller frees with std.c.free, so the malloc/free pairing is preserved (no valgrind
// allocator-boundary mismatch).
// tt-hashfull engine reader moved into engine.zig (M16.7).

// Native SearchManager construction + native Worker teardown:
//   * make: a raw search_manager_size buffer (operator new, so a matching operator delete
//     frees it valgrind-clean), zeroed — the manager's data fields are written by the
//     native reset shims (smReset*) + tm_init before every search, and updates@112 is set
//     to the engine UpdateContext for the main thread. No vtable, no ctor; check_time is
//     dead and pv() is native, so the vtable is never dispatched.
//   * destroy: free the rootMoves vector buffer + the manager by offset, then return the
//     large-page block. accumulatorStack/refreshTable are POD std::array members (trivial
//     dtors), so manager + rootMoves are the ONLY heap members ~Worker frees — reproducing
//     it without a virtual `delete manager`.
fn makeSearchManager(update_context: ?*const anyopaque, is_main: u8) ?*anyopaque {
    const buf = operatorNew(@sizeOf(graph_layout.SearchManager)) orelse return null;
    const bytes: [*]u8 = @ptrCast(buf);
    @memset(bytes[0..@sizeOf(graph_layout.SearchManager)], 0);
    if (is_main != 0) {
        graph_layout.SearchManager.fromPtr(@ptrCast(bytes)).updates = update_context;
    }
    return buf;
}
fn nativeWorkerDestroy(worker: ?*anyopaque) void {
    const w = worker orelse return;
    const base: [*]u8 = @ptrCast(w);
    // rootMoves vector buffer (begin @ root_moves+0); operator new'd by the RootMoves builder.
    const rm_begin: *?*anyopaque = @ptrCast(@alignCast(base + graph_layout.worker_off.root_moves));
    if (rm_begin.*) |b| operatorDelete(b);
    // SearchManager buffer (operator new'd by makeSearchManager above).
    const mgr: *?*anyopaque = @ptrCast(@alignCast(base + graph_layout.worker_off.manager));
    if (mgr.*) |m| operatorDelete(m);
    memory_port.alignedLargePagesFree(w);
}

// engine option registration moved into engine.zig (M16.7); initBody builds the
// native OptionsModel there via the option module directly.

// RootMoves ranked builder/destroyer relocated into thread.zig (M16.7).

// The `go` command owner. Builds a Search::LimitsType (120-byte POD; layout per
// graph_layout.limits_off — searchmoves std::vector<std::string>@0, then the TimePoints/
// ints/nodes/ponderMode) and hands it to the native go path (goEngine → start_thinking,
// which deep-copies it into each worker). The searchmoves vector is the libc++
// {begin@0,end@8,cap@16} header over an operator_new'd buffer of count 24-byte SSO
// std::strings (UCI moves are short, always SSO: byte0=size<<1, chars@+1). start_thinking
// copies limits synchronously, so the local searchmoves buffer is freed right after
// (matching the stack LimitsType destruction). Gate-covered by search-modes (searchmoves
// filtering) + teardown (the searchmoves vector alloc/free under valgrind).

// `go perft N` root divide. Reads the engine FEN, builds a scratch Position + StateInfo
// (operator_new'd, max-aligned), set()s it, generates the legal root moves natively, and
// per move runs the native perft subtree (do_move_state / perft_subtree / undo_move),
// printing "<move>: <count>" then the "Nodes searched: N" total — byte-exact (the `perft`
// parity harness diffs the divide output). Output routes through the coordinated output
// primitive. Gate-covered by the `perft` check (CPW positions + a chess960 castling position).

// The setoption owner. Waits for any search to finish, applies the assignment to the
// native option model, fires the on-change callback (spin/check relay the int + its
// decimal text, string relays the current value, button relays nothing), and routes the
// result + the "No such option" error through the coordinated output primitive. Mirrors
// print_info_string: split the message on '\n', skip whitespace-only lines, prefix each
// with "info string ".
// ModelSetResult lives in the option module now (option_port.ModelSetResult) -- M16.5.
// ThreadPool::boundThreadToNumaNode (std::vector<NumaIndex/size_t>) assign, reproduced on
// the native ThreadPool footprint vector {begin@40,end@48,cap@56}. count==0 (single-node — the only gated
// path) clears (end=begin). count>0 (multi-node) frees the old element buffer and operator_new's a fresh
// count*8 one (matched alloc/free family). Single-node never allocs, so valgrind/teardown stay clean.

// The native ThreadBuilder callback. Reads the native SharedState's five reference
// referents by offset (options@0, threads@8, tt@16, sharedHistories@24, network@32 —
// shared_state.zig's 40-byte bundle), mints the SearchManager, large-page-allocs + natively
// constructs the Worker, and writes the Worker at thread+8 (the worker@8 layout contract).
// Single-node host: numaIndex 0, idxInNuma == idx, totalNuma == ctx.total. A reference
// member's referent address equals the native field VALUE, so the field values are passed
// straight through.
const WorkerBuildCtx = struct {
    shared_state: ?*anyopaque,
    update_context: ?*const anyopaque,
    total: usize,
};
fn nativeWorkerBuild(ctx_ptr: ?*anyopaque, idx: usize, thread: *anyopaque) void {
    const ctx: *WorkerBuildCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const ss: [*]u8 = @ptrCast(ctx.shared_state.?);
    const ss_options = @as(*usize, @ptrCast(@alignCast(ss + 0))).*;
    const ss_threads = @as(*usize, @ptrCast(@alignCast(ss + 8))).*;
    const ss_tt = @as(*usize, @ptrCast(@alignCast(ss + 16))).*;
    const ss_shared_hist = @as(*usize, @ptrCast(@alignCast(ss + 24))).*;
    const ss_network = @as(*usize, @ptrCast(@alignCast(ss + 32))).*;
    const manager = makeSearchManager(ctx.update_context, if (idx == 0) @as(u8, 1) else 0) orelse
        @panic("native worker build: SearchManager OOM");
    const raw = memory_port.alignedLargePagesAlloc(graph_layout.worker_size) orelse
        @panic("native worker build: large-page OOM");
    const shared_history = engine_port.sharedHistoriesAt(@ptrFromInt(ss_shared_hist), 0);
    worker_native_construct.constructFull(
        raw,
        @intFromPtr(shared_history),
        ss_options,
        ss_threads,
        ss_tt,
        ss_network,
        @intFromPtr(manager),
        idx,
        idx,
        ctx.total,
        0,
    );
    @as(*usize, @ptrFromInt(@intFromPtr(thread) + 8)).* = @intFromPtr(raw);
}

// `new Position()` / `delete` ported native. Position has a defaulted trivial ctor and
// owns no heap (board arrays + pointers; StateListPtr is a type alias, not a member), so
// value-init == a zeroed position_size (1032B) block. operator new/delete keeps the
// alloc/free family matched (the trace_pos / pool throwaway Position is destroyed via
// operator delete).
// AccumulatorCaches create (`new AccumulatorCaches(network)`) moved into engine.zig (M16.7),
// now that the native FT biases pointer lives in the network module.

// `new AccumulatorStack()` / `delete` ported native. AccumulatorStack is POD (std::array
// members + a `size = 1` default member init), so value-init == a zeroed
// accumulator_stack_size block with size set to 1. The accumulator-stack reset on a zeroed
// buffer is exactly that (it sets size=1 and clears state-0's already-zero computed/diff
// fields), so it reproduces the ctor state. operator new/delete keeps the family matched.
// search tt-context: relocated into position.zig (M16.7).

// SearchManager::check_time inputs, snapshotted once per search tree. Mirrors the
// position.zig SearchTimeState exactly: live (mutable) fields are pointers; the
// fixed-per-search fields are values; calls_cnt is null off the main thread.

// search worker-state snapshot: relocated into position.zig (M16.7, network cycle broken).

// search prologue: relocated into position.zig (M16.7).

// search tm-init: relocated into position.zig (M16.7).

// get-best-thread: relocated into position.zig via the thread_vote leaf (M16.7).

// search id-collect-bmc: relocated into position.zig (M16.7).


// Skill(level, elo): a set UCI_Elo maps to a clamped [0,19] level; otherwise the level is
// the Skill Level option. enabled() == level < 20.

// search id-state + skillLevel: relocated into position.zig (M16.7).


// search context flags: relocated into position.zig (M16.7).


// search pv-context: relocated into position.zig (M16.7).

// ss-set-stop: relocated into position.zig (M16.7).

// ss-should-busywait: relocated into position.zig (M16.7).

// numa node-count / cpus-in-node single-node stubs moved into numa.zig (M16.7);
// engine.zig and thread.zig call the numa module directly.

pub fn engineInitBody(engine: *anyopaque) void {
    return engine_port.initBody(engine);
}

// Native engine container construct/destruct: build the heap members + inline sub-objects
// of the NativeEngine, and store argc/argv.
fn nativeEngineConstructMembers(buf: *anyopaque, argv0: [*:0]const u8) bool {
    return native_engine.constructMembers(buf, argv0);
}
fn nativeEngineSetCli(buf: *anyopaque, argc: c_int, argv: [*]const [*:0]u8) void {
    native_engine.setCli(buf, argc, argv);
}
// Native engine construction. Verify the object-graph footprint, build the heap members +
// inline sub-objects, store argc/argv, then run init_body (register options, set start
// position, size threads) — the same post-member work the UCIEngine ctor body did. The
// original also ran Tune::init(engine_options()), but Tune (SPSA) is INERT in a release
// build (no live TUNE() macros → instance().list is empty → init/read are empty loops;
// only the unused static Tune::options is set), so it is dropped here.
fn nativeUciEngineConstructAt(storage: *anyopaque, argc: c_int, argv: [*]const [*:0]u8) void {
    graph_layout.verifyLayouts();
    if (!nativeEngineConstructMembers(storage, argv[0]))
        @panic("native engine construct: member allocation failed");
    nativeEngineSetCli(storage, argc, argv);
    engineInitBody(storage);
}
fn nativeEngineDestructMembers(buf: *anyopaque) void {
    native_engine.destructMembers(buf);
}

pub fn releasePendingStateSlot(states_slot: *anyopaque) void {
    return engine_port.releasePendingStateSlot(states_slot);
}








// numa-config-from-option is applied inside engine.zig directly (M16.7).





// Native NumaConfig::to_string() for the single-node engine. Enumerates the process CPU
// affinity (sched_getaffinity — the same STARTUP_PROCESSOR_AFFINITY from_system reads) and
// formats it as the comma-separated CPU ranges to_string emits for ONE node (e.g. "0-7").
// Multi-node numa support was dropped (single-node decision), so there is no ":" node
// separator.
//
// M-PORT: sched_getaffinity/cpu_set_t are Linux-only. macOS/Windows have no per-thread affinity
// mask in the same shape, and the single-node default engine only needs "which CPUs may I run
// on"; there std.Thread.getCpuCount() gives the online count and the set is the contiguous range
// 0..n-1, formatted identically ("0-7", or "0" for one CPU).











// network load/verify/trace-evaluate/evaluate + the FT/layer weight storage and
// transform all live in network.zig (M16.7). The network->position cycle is now
// broken (network reads Position's side-to-move/board via the leaf graph_layout),
// so position calls network.evaluate directly.

// setoption parsing: uci.zig calls option.parseSetOption directly (M16.7).

// uci_to_cp: engine calls the leaf uci_wdl.toCp directly (M16.7).

// full-threats append (changed/active): nnue_accumulator.zig calls nnue_feature directly (M16.7).

// (large-page alloc/free + has-large-pages helpers retired -- M16.5: tt/position/misc
// call the `memory` module directly.)

// last-nodes-searched atomic + accessors moved into the uci_output leaf (M16.7);
// uci.zig reads it directly.




