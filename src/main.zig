const std = @import("std");
const c = @import("libc");

const engine_port = @import("engine");
const memory_port = @import("memory");
const uci_output = @import("uci_output");
const graph_layout = @import("graph_layout");
const native_hooks = @import("native_hooks");
const clock = @import("clock");
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
    const wl = graph_layout.WorkerLayout.fromPtr(worker);
    position_port.clearWorkerHistories(worker);
    // sharedHistory is a pointer stored inside the histories sub-block at
    // worker_shared_history_off; load it through the typed histories field.
    const sh_slot: *const usize = @ptrCast(@alignCast(&wl.histories[position_port.worker_shared_history_off]));
    const shared_history: *anyopaque = @ptrFromInt(sh_slot.*);
    position_port.clearSharedHistory(shared_history, wl.numa_thread_idx, wl.numa_total);
    search_port.fillReductions(&wl.reductions, 256);
    const biases: [*]const i16 = @ptrCast(@alignCast(network_port.nativeFtPtr() orelse return));
    nnue_accumulator_port.clearRefreshCache(&wl.refresh_table, biases);
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

fn pendingStatesAvailable(states_slot: *anyopaque) u8 {
    return engine_port.pendingStatesAvailable(states_slot);
}

fn handoffPendingStates(
    pool: *anyopaque,
    states_slot: *anyopaque,
) u8 {
    return engine_port.handoffPendingStates(pool, states_slot);
}

// Install the native runtime hooks: these impls live here because they need
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

// The engine buffer is a NativeEngine, so the member accessors return its fields
// (the heap member pointer for pointer-members; the field address for the inline
// states slot / update_context).
fn nativeEng(engine: *anyopaque) *native_engine.NativeEngine {
    return native_engine.NativeEngine.fromBuffer(engine);
}
// threads_ptr is main-internal only; engine.zig reaches the other graph slots
// through native_engine.zig accessors.
fn engineThreadsPtr(engine: *anyopaque) *anyopaque {
    return nativeEng(engine).threads.?;
}

// Free the side tt's large-page table at engine teardown + rezero for any re-construct
// (H5/valgrind). The table pointer lives at tt_off.table within the side storage.
fn freeSideTt() void {
    const table_ptr: *?*anyopaque = &graph_layout.TranspositionTable.fromPtr(native_engine.sideTtPtr()).table;
    if (table_ptr.*) |tbl| memory_port.alignedLargePagesFree(tbl);
    native_engine.sideTtReset();
}

// SharedState.sharedHistories (a reference) is the 4th pointer field of the
// native SharedState bundle (options/threads/tt/shared_histories/network); read
// it through the typed graph_layout.SharedState view and clear the native map.
fn sharedStateClearHistories(shared_state: *const anyopaque) void {
    engine_port.sharedHistoriesClear(graph_layout.SharedState.fromPtr(shared_state).shared_histories);
}
// insert_history: single-node never binds (do_bind always 0, numa_config unused) — insert
// directly into the native SharedHistoriesMap reached via the typed shared_histories field.
fn sharedStateInsertHistory(shared_state: *const anyopaque, numa_config: *const anyopaque, numa_index: usize, size: usize, do_bind: u8) void {
    _ = numa_config;
    _ = do_bind;
    engine_port.sharedHistoriesInsert(graph_layout.SharedState.fromPtr(shared_state).shared_histories, numa_index, size);
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

fn optInt(name: []const u8) c_int {
    return option_port.intByName(name);
}

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
    const wl = graph_layout.WorkerLayout.fromPtr(w);
    // rootMoves vector buffer (begin == root_moves[0]); operator new'd by the RootMoves builder.
    if (wl.root_moves[0] != 0) operatorDelete(@ptrFromInt(wl.root_moves[0]));
    // SearchManager buffer (operator new'd by makeSearchManager above).
    if (wl.manager) |m| operatorDelete(m);
    memory_port.alignedLargePagesFree(w);
}

// The native ThreadBuilder callback. Reads the native SharedState's five reference
// referents through the typed graph_layout.SharedState view (options/threads/tt/
// sharedHistories/network — the 40-byte bundle), mints the SearchManager, large-page-
// allocs + natively constructs the Worker, and writes the Worker through Thread.worker
// (the worker@8 layout contract). Single-node host: numaIndex 0, idxInNuma == idx,
// totalNuma == ctx.total. A reference member's referent address equals the native field
// VALUE, so the field values are passed straight through.
const WorkerBuildCtx = struct {
    shared_state: ?*anyopaque,
    update_context: ?*const anyopaque,
    total: usize,
};
fn nativeWorkerBuild(ctx_ptr: ?*anyopaque, idx: usize, thread: *anyopaque) void {
    const ctx: *WorkerBuildCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const ss = graph_layout.SharedState.fromPtr(ctx.shared_state.?);
    const manager = makeSearchManager(ctx.update_context, if (idx == 0) @as(u8, 1) else 0) orelse
        @panic("native worker build: SearchManager OOM");
    const raw = memory_port.alignedLargePagesAlloc(graph_layout.worker_size) orelse
        @panic("native worker build: large-page OOM");
    const shared_history = engine_port.sharedHistoriesAt(ss.shared_histories, 0);
    worker_native_construct.constructFull(
        raw,
        @intFromPtr(shared_history),
        @intFromPtr(ss.options),
        @intFromPtr(ss.threads),
        @intFromPtr(ss.tt),
        @intFromPtr(ss.network),
        @intFromPtr(manager),
        idx,
        idx,
        ctx.total,
        0,
    );
    graph_layout.Thread.fromPtr(thread).worker = @intFromPtr(raw);
}

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
// position, size threads) — the same post-member work the engine ctor body did. Tune (SPSA)
// is INERT in a release build (no live TUNE() macros → empty list), so it is dropped here.
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
