const std = @import("std");

const engine_port = @import("engine");
const memory_port = @import("memory");
const uci_output = @import("uci_output");
const worker_layout = @import("worker_layout");
const position_types = @import("position_types");
const runtime_hooks = @import("runtime_hooks");
const clock = @import("clock");
const time_source = @import("time_source");
const page_alloc = @import("page_alloc");
const thread_construct = @import("thread_construct.zig");
const worker_construct = @import("worker_construct.zig");
const engine_object = @import("engine_object"); // the engine object container
const misc_port = @import("misc");
const nnue_accumulator_port = @import("nnue_accumulator");
const network_port = @import("network");
const state_list_port = @import("state_list"); // the `states` member
const nnue_feature_port = @import("nnue_feature");
const option_port = @import("option");
const position_port = @import("position");
const search_driver = @import("search_driver");
const search_port = @import("search");
const thread_port = @import("thread");
const timeman_port = @import("timeman");
const uci_port = @import("uci");
const position_snapshot = @import("position_snapshot");

comptime {
    _ = worker_layout;
    _ = thread_construct;
    _ = worker_construct;
}

pub fn main(init: std.process.Init) !void {
    // Cross-platform argv: initAllocator handles Windows/WASI, where argv must be
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
    defer std.heap.c_allocator.free(std.mem.span(info));

    const info_line = std.mem.span(info);
    uci_output.printLine(info_line.ptr, info_line.len);

    // The movegen computes attacks/rays on the fly (bitboard.zig slidingAttack
    // etc.); the runtime tables come from position_port.initRuntime().
    position_port.initRuntime();
    installRuntimeHooks();

    // Zig-owned engine footprint: allocate aligned storage, placement-construct the
    // EngineObject (an ownership container of heap members) into it, and on teardown
    // destruct-in-place then free (defers run LIFO, so destruct precedes free).
    const eng_align = engine_object.alignofEngine();
    const eng_size = engine_object.sizeofEngine();
    const engine = memory_port.stdAlignedAlloc(eng_align, eng_size) orelse
        return error.OutOfMemory;
    defer memory_port.stdAlignedFree(engine);

    engineConstructAt(engine, @intCast(argc), argv.ptr);
    defer freeSideTt(); // free the side tt AFTER the engine destruct (LIFO)
    defer engine_port.freeSharedHistories(); // free the side sharedHistories map (after destruct)
    defer uciEngineDestructAt(engine);

    uci_port.loopRuntime(engine);
}

// The StateList backs the position-setup chain, the engine `states` slot
// (fallback root), and the pool's setupStates. PendingStateStorage carries move
// semantics (state_list.zig); the slot + setupStates hold a `?*StateList`, and
// adopt MOVEs the pointer + nulls the source.
const StateList = state_list_port.StateList;
const PendingStateStorage = state_list_port.PendingStateStorage;

fn poolSetupStatesSlot(pool: *worker_layout.ThreadPool) *?*StateList {
    return &pool.setup_states;
}
fn freeSetupStatesIfAny(pool: *worker_layout.ThreadPool) void {
    const slot = poolSetupStatesSlot(pool);
    if (slot.*) |old| {
        state_list_port.destroyStateList(std.heap.c_allocator, old);
        slot.* = null;
    }
}

// adopt: MOVE the StateList into the pool's setupStates, freeing any prior one
// (between searches setupStates still owns the previous list).
fn threadpoolSetupStatesAdoptFromStorage(pool: *worker_layout.ThreadPool, storage: *anyopaque) void {
    freeSetupStatesIfAny(pool);
    poolSetupStatesSlot(pool).* = @as(*PendingStateStorage, @ptrCast(@alignCast(storage))).moveOut();
}
fn threadpoolSetupStatesAdoptFromSlot(pool: *worker_layout.ThreadPool, slot_ptr: *anyopaque) void {
    freeSetupStatesIfAny(pool);
    const src: *?*StateList = @ptrCast(@alignCast(slot_ptr));
    poolSetupStatesSlot(pool).* = src.*;
    src.* = null;
}
fn threadpoolSetupStateBack(pool: *const worker_layout.ThreadPool) ?*const position_types.StateInfo {
    const slot = pool.setup_states;
    if (slot) |list| return list.back();
    return null;
}

// The worker-clear reset: the per-search worker reset the clear_worker job runs on
// its thread. The four clear helpers in declaration order: histories, the
// shared-history page (sharedHistory ref + numaThreadIdx@thread_idx+8 /
// numaTotal@+16), the reductions table (int[256], the 1024-byte slot before
// manager), and the refresh cache (feature-transformer biases). All four
// callees are gate-verified; only this orchestration is new.
fn workerClear(worker: *anyopaque) void {
    const wl = worker_layout.WorkerLayout.fromPtr(worker);
    search_driver.clearWorkerHistories(wl);
    // sharedHistory is now a typed field of the embedded WorkerHistories.
    const shared_history = wl.histories.shared_history.?;
    search_driver.clearSharedHistory(shared_history, wl.numa_thread_idx, wl.numa_total);
    search_port.fillReductions(&wl.reductions, 256);
    const biases: [*]const i16 = @ptrCast(@alignCast(network_port.ftPtr() orelse return));
    nnue_accumulator_port.clearRefreshCache(@ptrCast(&wl.refresh_table), biases);
}

fn pendingStatesAvailable(states_slot: *anyopaque) u8 {
    return engine_port.pendingStatesAvailable(states_slot);
}

fn handoffPendingStates(
    pool: *worker_layout.ThreadPool,
    states_slot: *anyopaque,
) u8 {
    return engine_port.handoffPendingStates(pool, states_slot);
}

// Install the runtime hooks: these impls live here because they need
// position/engine/network/search/state modules that already import their callers
// (thread/engine/search_thread), so the callers reach them through the runtime_hooks
// fn-pointer registry.
fn installRuntimeHooks() void {
    runtime_hooks.shared_state_clear_histories = &sharedStateClearHistories;
    runtime_hooks.shared_state_insert_history = &sharedStateInsertHistory;
    runtime_hooks.worker_destroy = &workerDestroy;
    runtime_hooks.worker_build = &workerBuild;
    runtime_hooks.worker_clear = &workerClear;
    runtime_hooks.setup_states_adopt_from_storage = &threadpoolSetupStatesAdoptFromStorage;
    runtime_hooks.setup_states_adopt_from_slot = &threadpoolSetupStatesAdoptFromSlot;
    runtime_hooks.setup_state_back = &threadpoolSetupStateBack;
    runtime_hooks.pending_states_available = &pendingStatesAvailable;
    runtime_hooks.handoff_pending_states = &handoffPendingStates;
    runtime_hooks.verify_thread_graph = &thread_construct.verifyThreadGraph;
    // Inject the platform monotonic clock into the engine's time-source seam, so
    // the search reads the OS clock without importing a platform module.
    time_source.now = &clock.now;
    // Inject the platform huge-page allocator into the engine's page-alloc seam, so
    // the big engine arenas allocate without importing a platform module.
    page_alloc.alloc = &memory_port.alignedLargePagesAlloc;
    page_alloc.free = &memory_port.alignedLargePagesFree;
}

// The engine buffer is a EngineObject, so the member accessors return its fields
// (the heap member pointer for pointer-members; the field address for the inline
// states slot / update_context).
fn engineObj(engine: *anyopaque) *engine_object.EngineObject {
    return engine_object.EngineObject.fromBuffer(engine);
}
// threads_ptr is main-internal only; engine.zig reaches the other graph slots
// through engine_object.zig accessors.
fn engineThreadsPtr(engine: *anyopaque) *worker_layout.ThreadPool {
    return engineObj(engine).threads.?;
}

// Free the side tt's large-page table at engine teardown + rezero for any re-construct
// (valgrind). The table pointer lives at tt_off.table within the side storage.
fn freeSideTt() void {
    const table_ptr = &worker_layout.TranspositionTable.fromPtr(engine_object.sideTtPtr()).table;
    if (table_ptr.*) |tbl| memory_port.alignedLargePagesFree(@ptrCast(tbl));
    engine_object.sideTtReset();
}

// SharedState.sharedHistories (a reference) is the 4th pointer field of the
// SharedState bundle (options/threads/tt/shared_histories/network); read
// it through the typed worker_layout.SharedState view and clear the map.
fn sharedStateClearHistories(shared_state: *const anyopaque) void {
    engine_port.sharedHistoriesClear(engine_port.SharedState.fromPtr(shared_state).shared_histories);
}
// insert_history: single-node never binds (do_bind always 0, numa_config unused) — insert
// directly into the SharedHistoriesMap reached via the typed shared_histories field.
fn sharedStateInsertHistory(shared_state: *const anyopaque, numa_config: *const anyopaque, numa_index: usize, size: usize, do_bind: u8) void {
    _ = numa_config;
    _ = do_bind;
    engine_port.sharedHistoriesInsert(engine_port.SharedState.fromPtr(shared_state).shared_histories, numa_index, size);
}
// With NNUE_EMBEDDING_OFF the embedded net is the 1-byte {0x0} stub; loadNetworkBytes
// fails on it and falls back to the on-disk EvalFile (bench validates the file net).
// set_loaded_state is a no-op: the load owns the EvalFile state (nn_current/
// nn_description, set just before these calls), so there is nothing more to record.
fn networkSetLoadedState(network: *anyopaque, current_name_ptr: [*]const u8, current_name_len: usize, description_ptr: [*]const u8, description_len: usize) void {
    _ = network;
    _ = current_name_ptr;
    _ = current_name_len;
    _ = description_ptr;
    _ = description_len;
}
// The read-blob fns are no-ops: weights are served from storage, so the parse
// result is discarded.
fn networkLayerReadBlob(network: *anyopaque, bucket: usize, data_ptr: [*]const u8, data_len: usize) usize {
    _ = network;
    _ = bucket;
    _ = data_ptr;
    _ = data_len;
    return 0;
}
// The engine object teardown. Free the states slot, join+free the threads + null the
// pool's threads vector, then free the heap members.
fn uciEngineDestructAt(storage: *anyopaque) void {
    releasePendingStateSlot(engine_object.EngineObject.fromPtr(storage).statesSlotPtr());
    thread_port.threadPoolClear(engineThreadsPtr(storage));
    engineDestructMembers(storage);
}

fn optInt(name: []const u8) c_int {
    return option_port.intByName(name);
}

// The SearchManager construction + the Worker teardown:
//   * make: a raw search_manager_size buffer, zeroed — the manager's data fields are
//     written by the reset shims (smReset*) + tm_init before every search, and
//     updates@112 is set to the engine UpdateContext for the main thread. No vtable,
//     no constructor; check_time is dead.
//   * destroy: free the rootMoves vector buffer + the manager by offset, then return the
//     large-page block. accumulatorStack/refreshTable are POD array members (no teardown),
//     so manager + rootMoves are the ONLY heap members the worker frees.
fn makeSearchManager(update_context: ?*const anyopaque, is_main: u8) ?*anyopaque {
    // A typed SearchManager via the Allocator interface (c_allocator, libc-backed).
    const sm = std.heap.c_allocator.create(worker_layout.SearchManager) catch return null;
    @memset(@as([*]u8, @ptrCast(sm))[0..@sizeOf(worker_layout.SearchManager)], 0);
    if (is_main != 0) sm.updates = update_context;
    return sm;
}
fn workerDestroy(worker: ?*anyopaque) void {
    const w = worker orelse return;
    const wl = worker_layout.WorkerLayout.fromPtr(w);
    // rootMoves buffer: a []RootMove allocated by workerSetRootMoves -- free the
    // slice directly.
    if (wl.root_moves.len != 0) std.heap.c_allocator.free(wl.root_moves);
    // SearchManager buffer (allocator.create'd by makeSearchManager; manager is typed).
    if (wl.manager) |m| std.heap.c_allocator.destroy(m);
    memory_port.alignedLargePagesFree(w);
}

// The ThreadBuilder callback. Reads the SharedState's five reference
// referents through the typed worker_layout.SharedState view (options/threads/tt/
// sharedHistories/network — the 40-byte bundle), mints the SearchManager, large-page-
// allocs + constructs the Worker, and writes the Worker through Thread.worker
// (the worker@8 layout contract). Single-node host: numaIndex 0, idxInNuma == idx,
// totalNuma == ctx.total. A reference member's referent address equals the field
// VALUE, so the field values are passed straight through.
const WorkerBuildCtx = struct {
    shared_state: ?*anyopaque,
    update_context: ?*const anyopaque,
    total: usize,
};
fn workerBuild(ctx_ptr: ?*anyopaque, idx: usize, thread: *anyopaque) void {
    const ctx: *WorkerBuildCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const ss = engine_port.SharedState.fromPtr(ctx.shared_state.?);
    const manager = makeSearchManager(ctx.update_context, if (idx == 0) @as(u8, 1) else 0) orelse
        @panic("worker build: SearchManager OOM");
    const raw = memory_port.alignedLargePagesAlloc(worker_layout.worker_size) orelse
        @panic("worker build: large-page OOM");
    const shared_history = engine_port.sharedHistoriesAt(ss.shared_histories, 0);
    worker_construct.constructFull(
        raw,
        @intFromPtr(shared_history),
        @intFromPtr(ss.threads),
        @intFromPtr(ss.tt),
        @intFromPtr(manager),
        idx,
        idx,
        ctx.total,
        0,
    );
    worker_layout.Thread.fromPtr(thread).worker = @ptrCast(@alignCast(raw));
}

pub fn engineInitBody(engine: *anyopaque) void {
    return engine_port.initBody(engine);
}

// The engine object container construct/destruct: build the heap members + inline sub-objects
// of the EngineObject, and store argc/argv.
fn engineConstructMembers(buf: *anyopaque, argv0: [*:0]const u8) bool {
    return engine_object.constructMembers(buf, argv0);
}
fn engineSetCli(buf: *anyopaque, argc: c_int, argv: [*]const [*:0]u8) void {
    engine_object.setCli(buf, argc, argv);
}
// The engine object construction. Verify the object-graph footprint, build the heap members +
// inline sub-objects, store argc/argv, then run init_body (register options, set start
// position, size threads) — the same post-member work the engine constructor runs. Tune (SPSA)
// is INERT in a release build (no live TUNE() macros → empty list), so it is dropped here.
fn engineConstructAt(storage: *anyopaque, argc: c_int, argv: [*]const [*:0]u8) void {
    worker_layout.verifyLayouts();
    if (!engineConstructMembers(storage, argv[0]))
        @panic("engine construct: member allocation failed");
    engineSetCli(storage, argc, argv);
    engineInitBody(storage);
}
fn engineDestructMembers(buf: *anyopaque) void {
    engine_object.destructMembers(buf);
}

pub fn releasePendingStateSlot(states_slot: *anyopaque) void {
    return engine_port.releasePendingStateSlot(states_slot);
}
