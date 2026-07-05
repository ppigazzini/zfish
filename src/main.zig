const std = @import("std");
const builtin = @import("builtin");
const c = @import("libc");

const benchmark_port = @import("benchmark");
const bitboard_port = @import("bitboard");
const engine_port = @import("engine");
const memory_port = @import("memory");
const uci_output = @import("uci_output");
const graph_layout = @import("graph_layout");
const clock = @import("clock");
const worker_construct = @import("worker_construct.zig");
const thread_construct = @import("thread_construct.zig");
const worker_native_construct = @import("worker_native_construct.zig");
const native_engine = @import("native_engine"); // M-FINAL native engine container (cutover)
const misc_port = @import("misc");
const movegen_port = @import("movegen");
const movepick_port = @import("movepick");
const nnue_accumulator_port = @import("nnue_accumulator");
const network_port = @import("network");
const network_holder = @import("network_holder"); // native `network` holder (cut)
const state_list_port = @import("state_list"); // native `states` member (cut)
const numa_config_port = @import("numa_config"); // native `numaContext` member (cut)
const position_storage_port = @import("position_storage"); // native `position` member (cut)
const nnue_feature_port = @import("nnue_feature");
const option_port = @import("option");
const position_port = @import("position");
const search_port = @import("search");
const score_port = @import("score");
const thread_port = @import("thread");
const evaluate_port = @import("evaluate");
const nnue_misc_port = @import("nnue_misc");
const timeman_port = @import("timeman");
const tt_port = @import("tt");
const uci_port = @import("uci");
const position_snapshot = @import("position_snapshot");
const uci_move_port = @import("uci_move");

comptime {
    _ = graph_layout;
    _ = worker_construct;
    _ = thread_construct;
    _ = worker_native_construct;
}

const PositionSnapshot = position_snapshot.PositionSnapshot;

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

    const info = zfish_misc_engine_info_text() orelse return error.OutOfMemory;
    defer c.free(@ptrCast(info));

    _ = c.puts(@ptrCast(info));

    // The native movegen computes attacks/rays on the fly (bitboard.zig slidingAttack
    // etc.); the runtime tables come from position_port.initRuntime().
    position_port.initRuntime();

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

pub fn zfish_misc_engine_info_text() ?[*:0]u8 {
    return misc_port.engineInfoText(0);
}

pub fn zfish_position_undo_move_method(pos_ptr: *anyopaque, move: u16) void {
    position_port.undoMove(pos_ptr, move);
}

// do_move that links a fresh StateInfo and computes givesCheck internally
// (Position::do_move(Move, StateInfo&)); exported from the bridge.

// Recursive perft node counter. Replaces the C++ Benchmark::perft recursion:
// the bridge keeps the root divide loop (for byte-identical per-move output and
// MoveList ordering) and calls this for each root move's subtree. Reuses the
// Zig legal movegen and the do_move/undo_move seam the search already drives.
const perft_max_depth = 64;
const PerftStateBuf = [graph_layout.state_info_size]u8;

fn perftCount(pos_ptr: *anyopaque, depth: c_int, states: *[perft_max_depth]PerftStateBuf, ply: usize) u64 {
    if (depth <= 0) return 1;
    var moves: [256]u16 = undefined;
    const n = movegen_port.generateLegal(pos_ptr, &moves);
    if (depth == 1) return n; // leaf: legal-move count
    var nodes: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        position_port.doMoveState(pos_ptr, moves[i], &states[ply]);
        nodes += perftCount(pos_ptr, depth - 1, states, ply + 1);
        zfish_position_undo_move_method(pos_ptr, moves[i]);
    }
    return nodes;
}

pub fn zfish_perft_subtree(pos_ptr: *anyopaque, depth: c_int) u64 {
    const capped = if (depth > perft_max_depth) perft_max_depth else depth;
    var states: [perft_max_depth]PerftStateBuf align(64) = undefined;
    return perftCount(pos_ptr, capped, &states, 0);
}

// M-FINAL cutover (position-set port): native Position::set (FEN parse) + legality, replacing
// the C++ Position::set / Position::legal in the bridge. The live pos is the Zig side block, so
// these operate on the same byte-compatible storage the native search reads. Default-only
// (legacy keeps the C++ Position methods); gate-verified by search-parity (51 FENs) + bench.
fn zfishPositionMoveIsLegal(pos_ptr: *const anyopaque, raw_move: u16) callconv(.c) u8 {
    return @intFromBool(position_port.legal(pos_ptr, raw_move));
}
// M-FINAL cutover (thread-cluster leaf): native TT-slice zero. In the default build the
// pool holds native Threads (no C++ run_custom_job vehicle); the TT clear is a deterministic
// memset whose result is thread-independent, so zero the slice synchronously on the caller
// (the paired wait_thread no-ops). Matches the C++ #else branch byte-for-byte. Legacy keeps
// the C++ ThreadPool::run_on_thread path.
// M-FINAL cutover (states crack): native StateList replaces the C++ deque<StateInfo> across the
// storage (position-setup chain), the engine `states` slot (fallback root), and the pool's
// setupStates@8. PendingStateStorage carries the unique_ptr MOVE semantics (state_list.zig).
// The slot + setupStates@8 hold a `?*StateList`; adopt MOVEs the pointer + nulls the source.
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

fn zfishStateListStorageDestroy(storage: ?*anyopaque) callconv(.c) void {
    if (storage) |s| @as(*PendingStateStorage, @ptrCast(@alignCast(s))).destroy();
}
fn zfishStateListStoragePush(storage: *anyopaque) callconv(.c) *anyopaque {
    return @as(*PendingStateStorage, @ptrCast(@alignCast(storage))).push() catch @panic("OOM: state push");
}
// engine `states` slot: a ?*StateList. reset() mirrors unique_ptr::reset() — free + null
// (the slot is the rarely-used fallback; the storage chain is what searches normally adopt).
// adopt: MOVE the StateList into the pool's setupStates@8, freeing any prior one (between
// searches setupStates still owns the previous list; ~ThreadPool no longer frees it).
fn zfishThreadpoolSetupStatesAdoptFromStorage(pool: *anyopaque, storage: *anyopaque) callconv(.c) void {
    freeSetupStatesIfAny(pool);
    poolSetupStatesSlot(pool).* = @as(*PendingStateStorage, @ptrCast(@alignCast(storage))).moveOut();
}
fn zfishThreadpoolSetupStatesAdoptFromSlot(pool: *anyopaque, slot_ptr: *anyopaque) callconv(.c) void {
    freeSetupStatesIfAny(pool);
    const src: *?*StateList = @ptrCast(@alignCast(slot_ptr));
    poolSetupStatesSlot(pool).* = src.*;
    src.* = null;
}
fn zfishThreadpoolSetupStateBack(pool: *const anyopaque) callconv(.c) ?*anyopaque {
    const slot: ?*StateList = @ptrCast(@alignCast(graph_layout.ThreadPool.fromPtr(@constCast(pool)).setup_states));
    if (slot) |list| return list.back();
    return null;
}

// M-FINAL cutover (thread cluster): native ThreadPool::setupStates null-check. setupStates is
// a StateListPtr (single pointer) at ThreadPool.setup_states; has-states == ptr != null.
// Pure offset read (no deque internals). Default-only (legacy keeps the C++ method).

fn zfishThreadpoolZeroTtSlice(
    threads_ptr: *anyopaque,
    thread_id: usize,
    table_ptr: ?*anyopaque,
    start_cluster: usize,
    cluster_len: usize,
) callconv(.c) void {
    _ = threads_ptr;
    _ = thread_id;
    if (cluster_len == 0) return;
    const table = table_ptr orelse return;
    const cs = @sizeOf(tt_port.TtCluster);
    const base: [*]u8 = @ptrCast(table);
    @memset(base[start_cluster * cs .. (start_cluster + cluster_len) * cs], 0);
}

pub fn zfish_position_flip_fen(fen_ptr: [*]const u8, fen_len: usize) ?[*:0]u8 {
    return position_port.flipFen(fen_ptr, fen_len);
}

pub fn zfish_position_set_method(
    pos_ptr: *anyopaque,
    fen_ptr: [*]const u8,
    fen_len: usize,
    is_chess960: u8,
    st_ptr: *anyopaque,
    pos_size: usize,
    st_size: usize,
) ?[*:0]u8 {
    return position_port.setPosition(pos_ptr, fen_ptr, fen_len, is_chess960, st_ptr, pos_size, st_size);
}


// zfish_search_stat_bonus/stat_malus retired -- position.zig calls search directly (M16.5).



pub fn zfish_search_extract_ponder_from_tt(pv: *anyopaque, table: ?*anyopaque, cc: usize, gen: u8, pos: *anyopaque) u8 {
    return position_port.extractPonderFromTt(pv, table, cc, gen, pos);
}

pub export fn zfish_position_fill_snapshot(pos_ptr: *const anyopaque, out: *anyopaque) void {
    position_port.fillSnapshot(pos_ptr, out);
}


// Native-graph cut flip fire 2: shadow verifier. The bridge calls this right after the
// C++ try_emplace builds a node's SharedHistories, so the native sizing logic (the
// builder the flip will use) is diffed against the live oracle every engine
// construction. Returns false (and logs) on any mismatch; the bridge aborts loudly.
pub fn zfish_shadow_verify_shared_histories(shared: *const anyopaque, thread_count: usize) bool {
    const ok = position_port.verifySharedHistories(shared, thread_count);
    if (!ok) {
        std.debug.print(
            "zfish: shadow_verify_shared_histories MISMATCH (thread_count={d}) -- " ++
                "native SharedHistories sizing diverged from the C++ try_emplace\n",
            .{thread_count},
        );
    }
    return ok;
}


// Native Worker::clear (stage-4 layer 5): the per-search worker reset the native
// clear_worker job runs on its thread. Reproduces Search::Worker::clear() by
// offset -- the four native clear helpers in declaration order: histories, the
// shared-history page (sharedHistory ref + numaThreadIdx@thread_idx+8 /
// numaTotal@+16), the reductions table (int[256], the 1024-byte slot before
// manager), and the refresh cache (native feature-transformer biases). All four
// callees are gate-verified; only this orchestration is new.
pub export fn zfish_worker_clear(worker: *anyopaque) void {
    const wb = @intFromPtr(worker);
    const off = graph_layout.worker_off;
    position_port.clearWorkerHistories(worker);
    const shared_history: *anyopaque = @ptrFromInt(@as(*const usize, @ptrFromInt(wb + off.shared_history)).*);
    const numa_thread_idx = @as(*const usize, @ptrFromInt(wb + off.thread_idx + 8)).*;
    const numa_total = @as(*const usize, @ptrFromInt(wb + off.thread_idx + 16)).*;
    position_port.clearSharedHistory(shared_history, numa_thread_idx, numa_total);
    const reductions: [*]c_int = @ptrFromInt(wb + off.reductions);
    search_port.fillReductions(reductions, 256);
    const refresh: *anyopaque = @ptrFromInt(wb + off.refresh_table);
    const biases: [*]const i16 = @ptrCast(@alignCast(network_port.nativeFtPtr() orelse return));
    nnue_accumulator_port.clearRefreshCache(refresh, biases);
}

// Stage 5: native Worker::set_root_moves -- the C++ `rootMoves = value` copy-assign
// of a std::vector<RootMove>, reproduced by offset. RootMove is standard-layout
// POD (PVMoves is a fixed Move[] array), so a non-empty assign is one memcpy of
// count*sizeof(RootMove). The dest buffer lives in the C++ Worker and is freed by
// ~Worker -> ~vector -> ::operator delete, so any (re)allocation here must use
// ::operator new (zfish_operator_new), matching libc++'s allocator. Mirrors
// std::vector copy-assign: reuse the buffer when capacity suffices, else realloc.
// REPORT-12 TU=0: native default-only allocator (the last default C++ bodies in uci_bridge.cpp).
// ::operator new/delete bottom out in malloc/free, so they are an interchangeable matched alloc/free
// family for the native containers (RootMoves/searchmoves/bound_nodes/Position/caches) — verified by
// parity-valgrind + parity-teardown. The legacy oracle keeps its own libc++ ::operator new/delete.
fn zfishOperatorNew(n: usize) callconv(.c) ?*anyopaque {
    return std.c.malloc(n);
}
fn zfishOperatorDelete(p: ?*anyopaque) callconv(.c) void {
    std.c.free(p);
}

// LimitsType layout anchors + worker limits/root-moves setters relocated to thread.zig (M16.7).

// M-FINAL (limits readers): pure LimitsType offset reads — no allocation, so no Zig<->C++
// allocator-boundary mismatch (the trap that blocks porting operator new/delete). Offsets
// from graph_layout.limits_off (verified vs src/search.h LimitsType field order). Exported
// default-only (comptime block below); the legacy oracle keeps the C++ defs under #ifdef.
fn zfishLimitsPerftValue(limits: *const anyopaque) callconv(.c) usize {
    return @intCast(graph_layout.LimitsType.fromPtr(@constCast(limits)).perft);
}

// Stage 5: native Worker::set_limits -- the C++ `limits = value` copy of LimitsType.
// Copies only the POD tail (everything after the leading std::vector<std::string>
// searchmoves). The Worker's searchmoves copy is vestigial (the search filters root
// moves from the source limits at root setup, never from worker.limits), so we
// leave it at the zeroed-empty state worker construction set -- valid for ~vector,
// no string-ABI deep copy, no leak. POD tail starts right after searchmoves.

// zfish_search_quiet_{low_ply,cont,pawn}_scale retired -- position.zig calls search directly (M16.5).

// conthist-delta: position.zig calls search.conthistDelta directly (M16.7).

// movegen capture/quiet/evasion generation: movepick.zig calls the movegen module
// directly (M16.7).


// thread start-thinking: engine calls thread.startThinking directly (M16.7).

pub export fn zfish_engine_pending_states_available(states_slot: *anyopaque) u8 {
    return engine_port.pendingStatesAvailable(states_slot);
}

pub export fn zfish_engine_handoff_pending_states(
    pool: *anyopaque,
    states_slot: *anyopaque,
) u8 {
    return engine_port.handoffPendingStates(pool, states_slot);
}

// threadpool reconfigure: engine calls thread.reconfigure directly (M16.7).


pub fn zfish_threadpool_start_searching(pool: *anyopaque) void {
    return thread_port.startSearching(pool);
}



pub fn zfish_threadpool_nodes_searched(pool: *anyopaque) u64 {
    return thread_port.nodesSearched(pool);
}

// REPORT-12 B4b: side-to-move of a Position by pointer, for the bridge's de-typed
// zfish_ss_npmsec_advance (rootPos.side_to_move() once Position is forward-declared). Reuses the
// native layout authority (position_port.sideToMove), so no C++ offset needs pinning.
pub fn zfish_ss_side_to_move(pos: *const anyopaque) u8 {
    return position_port.sideToMove(pos);
}

// Native SearchManager data-field shims. The main manager's data members are
// written through the C++ navigation helper (which returns the manager pointer)
// plus the search_manager_off offset map, so these resets no longer use the C++
// SearchManager type -- they replace the former C++ main_manager()-> field shims.
// Exported only in the default build: the legacy oracle keeps src/thread.cpp's
// definitions, so gating the @export avoids a duplicate-symbol link error.
extern fn zfish_threadpool_main_manager_ptr(pool: *anyopaque) ?*anyopaque;

fn smMgr(pool: *anyopaque) ?*graph_layout.SearchManager {
    return graph_layout.SearchManager.fromPtr(zfish_threadpool_main_manager_ptr(pool) orelse return null);
}

fn smResetBestPreviousScore(pool: *anyopaque) callconv(.c) void {
    if (smMgr(pool)) |m| m.best_previous_score = 32001; // VALUE_INFINITE
}
fn smResetOriginalTimeAdjust(pool: *anyopaque) callconv(.c) void {
    if (smMgr(pool)) |m| m.original_time_adjust = -1;
}
fn smSetPonder(pool: *anyopaque, ponder_mode: u8) callconv(.c) void {
    if (smMgr(pool)) |m| m.ponder = if (ponder_mode != 0) 1 else 0;
}
fn smClearTimeman(pool: *anyopaque) callconv(.c) void {
    // TimeManagement::clear() sets availableNodes = -1; nothing else.
    if (smMgr(pool)) |m| m.tm.available_nodes = -1;
}

// Native ThreadPool flag shims: stop and increaseDepth are the leading
// std::atomic_bool pair at pool+0 / pool+1. Written directly (single-threaded
// setup context), gated to the default build alongside the manager shims.
fn tpSetIncreaseDepth(pool: *anyopaque, increase_depth: u8) callconv(.c) void {
    graph_layout.ThreadPool.fromPtr(pool).increase_depth = if (increase_depth != 0) 1 else 0;
}
// Native Thread->worker field reads. thread+8 holds the Worker pointer; read the
// relaxed-atomic u64 counters at the worker's nodes/tbHits offsets. Match
// Thread::worker_nodes_searched()/worker_tb_hits(). Gated to the default build.
fn threadWorker(thread: *const anyopaque) ?[*]const u8 {
    const w = graph_layout.Thread.fromPtr(@constCast(thread)).worker;
    if (w == 0) return null;
    return @ptrFromInt(w);
}
fn thTbHits(thread: *const anyopaque) callconv(.c) u64 {
    const w = threadWorker(thread) orelse return 0;
    const p: *const u64 = @ptrCast(@alignCast(w + graph_layout.worker_off.tb_hits));
    return p.*;
}


// ThreadPool::thread_at(i) == threads[i].get(): the i-th unique_ptr<Thread> in
// the threads vector is a single pointer, so .get() is the loaded slot value.
// begin() is the vector's begin pointer at threads_begin; element stride is the
// 8-byte unique_ptr.
// Mutable Thread -> Worker resolution (LargePagePtr<Worker> at Thread+8).
fn threadWorkerMut(thread: *anyopaque) ?[*]u8 {
    const w = graph_layout.Thread.fromPtr(thread).worker;
    if (w == 0) return null;
    return @ptrFromInt(w);
}

// Worker::reset_root_setup_state zeros the five per-search counters. They are POD
// (the two node counters are atomics, but a relaxed store of 0 is a plain zero
// write), so each is set through the worker offset map.

// Matches the bridge ZfishTbConfig / thread.zig TbConfig C-ABI struct passed by
// value: {int cardinality; u8 root_in_tb; u8 use_rule50; int probe_depth}.
const WorkerTbConfig = extern struct {
    cardinality: c_int,
    root_in_tb: u8,
    use_rule50: u8,
    probe_depth: c_int,
};

// Worker::set_tb_config assigns worker.tbConfig = Tablebases::Config{...}. The
// Config is POD {int cardinality; bool rootInTB; bool useRule50; Depth(int)
// probeDepth} laid out as cardinality@0, rootInTB@4, useRule50@5, probeDepth@8.
// The bridge normalized the two flags with `!= 0`, so booleans are written 0/1.
// Padding bytes (+6,+7) are never read by the search, so they are left alone.

// Worker::set_root_state assigns worker.rootState = value. StateInfo is fully POD
// (scalars plus one raw `previous` pointer), so the C++ member-wise copy is a
// byte copy; the native version memcpy's the 192-byte StateInfo into the Worker
// rootState slot.

// Worker::set_root_position runs rootPos.set(fen, chess960, &rootState). Position
// set is already native (position_port.setPosition, also exported as
// zfish_position_set_method); the dispatcher resolves the in-Worker rootPos and
// rootState by offset and runs it, discarding the error string exactly as the
// C++ set_root_position discards the returned Position&.


// M-FINAL: pool->main_manager() = main_thread()->worker->main_manager() as native offset
// navigation: thread[0] -> worker@thread_off.worker -> manager@worker_off.manager (the
// unique_ptr<ISearchManager>'s stored pointer == the SearchManager* for the main thread).
// Default-only; the legacy oracle keeps the C++ ThreadPool::main_manager() method.
fn zfishThreadpoolMainManagerPtr(pool: *anyopaque) callconv(.c) ?*anyopaque {
    const thread0 = graph_layout.ThreadPool.fromPtr(pool).threadAtPtr(0);
    const worker = graph_layout.Thread.fromPtr(thread0).worker;
    if (worker == 0) return null;
    return @ptrFromInt(@as(*const usize, @ptrFromInt(worker + graph_layout.worker_off.manager)).*);
}

// Stage-7 7.1: native-inert tablebase probe entry points for the default build.
// The Zig runtime ships no Syzygy tablebases (max cardinality 0 -> the native
// probe path short-circuits before ever probing), so these report "unavailable"
// and init is a no-op. The legacy oracle keeps the real bridge versions (which
// call src/syzygy/tbprobe.cpp) behind ZFISH_LEGACY_CPP_TARGET; routing the
// default build through these lets the default-only C++ Tablebases stub block in
// the bridge be deleted (no default reference to Tablebases:: remains).




// REPORT-12 TU=0 grind: the NumaPolicy setters are no-ops in the default build — the numa context is
// a fixed single-node native stub, so reconfiguring it does nothing (and must not touch the stub).
// Native no-op replaces the C++ default stubs; the legacy oracle keeps the real C++ set_numa_config.
fn numaSuggestsBindingThreads(_: *const anyopaque, _: usize) callconv(.c) u8 {
    return 0;
}
fn numaExecuteOnNode(_: *const anyopaque, _: usize, callback: *const fn (?*anyopaque) callconv(.c) void, context: ?*anyopaque) callconv(.c) void {
    callback(context);
}

comptime {
    // id_state reads the native option model (default-only populated), so the
    // native version is default-only; legacy keeps the bridge C++ body.
    // M-FINAL (limits readers): pure LimitsType offset reads (legacy keeps the C++ defs).
    // M-FINAL (option readers): native OptionsModel reads (legacy keeps OptionsMap[]).
    // M-FINAL (string-option readers): native OptionsModel string reads (legacy keeps C++).
    // NumaPolicy setters: native no-op in default (single-node stub); legacy keeps the C++ defs.
    @export(&engineEmitVerifyMessage, .{ .name = "zfish_engine_emit_verify_message" });
    @export(&sharedStateClearHistories, .{ .name = "zfish_shared_state_clear_histories" });
    @export(&sharedStateInsertHistory, .{ .name = "zfish_shared_state_insert_history" });
    // M-FINAL: clock + chess960 flag + searchmoves[i] text (legacy keeps the C++ defs).
    // M-FINAL: tt ops via native tt.zig (legacy keeps the C++ TranspositionTable methods).
    // M-FINAL: main_manager navigation (legacy keeps the C++ ThreadPool::main_manager()).
    @export(&zfishThreadpoolMainManagerPtr, .{ .name = "zfish_threadpool_main_manager_ptr" });
    // M-FINAL / M-SM: native SearchManager construct + native Worker teardown (cracks the
    // virtual-dtor wall). Legacy keeps the C++ SearchManager + ~Worker.
    @export(&zfishNativeWorkerDestroy, .{ .name = "zfish_native_worker_destroy" });
    @export(&nativeWorkerBuild, .{ .name = "zfish_native_worker_build" });
    @export(&goParsedOwner, .{ .name = "zfish_engine_go_parsed_owner" });
    @export(&perftOwner, .{ .name = "zfish_engine_perft_owner" });
    @export(&threadpoolBoundNodesAssign, .{ .name = "zfish_threadpool_bound_nodes_assign" });
    // M-FINAL: native Position construct/destroy (legacy keeps new/delete Position).
    // AccumulatorCaches create moved into engine.zig (M16.7).
    // M-FINAL: native AccumulatorStack construct/destroy (legacy keeps new/delete).
    // M-FINAL cutover: native engine container construct/destruct (not yet on the live
    // path; the flip commit wires these). Default-only — legacy keeps the C++ UCIEngine.
    // M-FINAL cutover (position-set port): native Position::set + legality (legacy keeps C++).
    @export(&zfishPositionMoveIsLegal, .{ .name = "zfish_position_move_is_legal" });
    // M-FINAL cutover (thread-cluster leaf): native TT-slice zero (legacy keeps C++ run_on_thread).
    @export(&zfishThreadpoolZeroTtSlice, .{ .name = "zfish_threadpool_zero_tt_slice" });
    // M-FINAL cutover (states crack): native StateList storage/slot/adopt/back (legacy keeps C++ deque).
    @export(&zfishThreadpoolSetupStatesAdoptFromStorage, .{ .name = "zfish_threadpool_setup_states_adopt_from_storage" });
    @export(&zfishThreadpoolSetupStatesAdoptFromSlot, .{ .name = "zfish_threadpool_setup_states_adopt_from_slot" });
    @export(&zfishThreadpoolSetupStateBack, .{ .name = "zfish_threadpool_setup_state_back" });
}

// REPORT-10 (pos migration): the engine `pos` is now a NATIVE side-allocated Position
// block, not the C++ Engine's embedded `pos` member. sizeof(Position)==1032; Position is
// POD-ish (its `st` points to the separate states list — no owned heap), so a zeroed
// static block needs no teardown free, and init_body's pos.set(StartFEN) fills it through
// this accessor. The native position ops (position.zig) operate on it; setPosition /
// start_thinking / fen all reach it via this accessor. The C++ Engine pos stays dead.
// M-FINAL cutover: in the default build the engine buffer is a NativeEngine, so the
// member accessors return its fields (the heap member pointer for pointer-members; the
// field address for the inline states slot / update_context). The legacy oracle keeps
// the inline-into-C++-Engine offset reads.
fn nativeEng(engine: *anyopaque) *native_engine.NativeEngine {
    return native_engine.NativeEngine.fromBuffer(engine);
}
// Engine graph pointer accessors (numa_context / update_context) were unused C-ABI
// exports -- engine.zig reaches those slots through native_engine.zig accessors --
// so they are dropped (M16.7). threads_ptr is main-internal only, kept un-exported.
fn engineThreadsPtr(engine: *anyopaque) *anyopaque {
    return nativeEng(engine).threads.?;
}
// REPORT-10 M1 (tt migration, side-allocation): the engine's tt is now a NATIVE
// side-allocated TranspositionTable, not the C++ Engine's embedded `tt` member. The
// engine is a singleton on the gate, so a freed-and-rezeroed global suffices. Layout
// matches the C++ TT (tt_off: cluster_count@0, table@8, generation@16) since the C++
// SharedState binds this pointer; 64 bytes generously covers sizeof(TranspositionTable).
// init_body resizes it through this accessor; the C++ Engine's tt stays dead until
// M-FINAL. Native ops (resizeState/clearState/probe) operate via tt_off; sizing is the
// SAME native code, so the side tt is bit-identical (bench 2336177 gates it).

// Free the side tt's large-page table at engine teardown + rezero for any re-construct
// (H5/valgrind). The table pointer lives at tt_off.table within the side storage.
fn freeSideTt() void {
    const table_ptr: *?*anyopaque = &graph_layout.TranspositionTable.fromPtr(native_engine.sideTtPtr()).table;
    if (table_ptr.*) |tbl| memory_port.alignedLargePagesFree(tbl);
    native_engine.sideTtReset();
}
// The engine's native SharedHistoriesMap side storage + its clear/insert/at/free
// operations moved into engine.zig (M16.7): the map is engine-owned, so the bridge
// sites below reach it through the engine module (engine_port.sharedHistories*).
// REPORT-12 TU=0 grind: default build's network_ptr is a pass-through to network_replicated_ptr
// (the native verify/eval ignore the value). Default-only @export; legacy keeps the C++ wrapper deref.
// SharedState create/destroy: engine.zig now calls shared_state.zig directly (M16.7).
// REPORT-12 TU=0 grind: the _info_text display fns are pure pass-throughs to the already-native
// *_information_owner fns — the owner already returns a malloc'd C string the caller frees with
// c.free, so the C++ wrappers' std::string re-copy was redundant. Default-only; legacy keeps C++.
fn engineThreadAllocationInfoText(engine_ptr: *const anyopaque) callconv(.c) ?[*:0]u8 {
    return engine_port.threadAllocationInformationEngine(engine_ptr);
}
// REPORT-12 TU=0 grind: the "uci" option listing is rendered from the native Zig option model;
// the default options_text_owner already just returned option_port.zfish_optmodel_render(). Pure pass-through.
// options-text: uci.zig calls option.render directly (M16.7).
// engine flip: uci.zig calls engine.flipEngine directly (M16.7).
// REPORT-12 TU=0 grind: set the start position via the native set-position machinery (StartFEN is a
// constexpr literal; the value is gate-verified by misc + bench, which start from this position).
// UCIEngine::engine is the first member (offset 0): the accessor is the identity.
// UCIEngine::engine is the first member (offset 0), so the accessor was the
// identity: uci.zig now uses the engine pointer directly (M16.7).
// ThreadPool::num_threads() == threads.size() (bridge-only symbol, no gating).

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


// zfish_search_emit_info_full: build one "info ..." line natively and print it.
// Always records the node count (as the C++ onUpdateFull lambda did in both
// modes); prints only in interactive mode. The score classification, cp/mate
// formatting, WDL, and PV rendering are all native; the line assembly reuses
// uci_port.formatInfoFull. Bridge-only symbol, no gating.

// zfish_ss_set_prev_scores: w->main_manager()->bestPreviousScore =
// b->rootMoves[0].score, and likewise bestPreviousAverageScore. Reads the two
// Value ints from best's first RootMove and stores them in worker's manager
// (bridge-only symbol, no gating).
// zfish_ss_set_prev_scores: relocated into position.zig (M16.7).

fn workerTT(worker: *const anyopaque) usize {
    const p: *const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(worker)) + graph_layout.worker_off.tt));
    return p.*;
}

// zfish_ss_pv_one_and_ponder: best->rootMoves[0].pv.size() == 1 &&
// best->rootMoves[0].extract_ponder_from_tt(worker->tt, worker->rootPos). The pv
// and length come from best's first RootMove; the TT (table/clusterCount/
// generation8) and rootPos come from worker. extract_ponder mutates pv exactly as
// the C++ does. Bridge-only symbol, no gating.
// zfish_ss_pv_one_and_ponder: relocated into position.zig (M16.7).

// Native quiet-mode flag, mirrored from the C++ zfish_uci_set_listener_mode. In
// quiet mode (bench/speedtest) the search-driver emit functions are no-ops; in
// interactive mode they format natively and print through the shared sync_cout
// wrapper.
pub fn zfish_uci_set_quiet_mode(quiet: u8) void {
    uci_output.setQuietMode(quiet != 0);
}

// REPORT-12 TU=0: the native output primitive (replacing the C++ sync_cout wrapper zfish_uci_print_line +
// the Tie logger). Writes one mutex-guarded, flushed line to libc stdout — the SAME FILE* the rest of the
// native UCI output uses (uci.zig c.puts), so there is no buffered/unbuffered interleave — and tees it to
// the Log File when one is open. (In the default build the C++ Tie only ever saw this output anyway: the
// native loop reads stdin + writes via libc, bypassing the C++ cin/cout streams.)
// The UCI info/bestmove emit is main-thread-only (the on_update_full path), so no IO lock is needed —
// matching the single output stream. fflush mirrors the C++ sync_endl flush.
// The native UCI output primitive (printLine) + log-file sink + portable cStdout
// moved into the uci_output leaf module (M16.7); main and engine call it directly.

// REPORT-12 TU=0 std::function cluster Step D: the network-verify message emitter. The C++ version
// invoked the onVerifyNetwork std::function (print_info_string interactive / no-op quiet); that
// std::function is now legacy-only, so this native default-only version reproduces it exactly —
// no-op in quiet mode, else format as an "info string" and print through the shared sync_cout wrapper.
fn engineEmitVerifyMessage(engine_ptr: *const anyopaque, message_ptr: [*]const u8, message_len: usize) callconv(.c) void {
    _ = engine_ptr;
    if (uci_output.isQuiet()) return;
    const formatted = zfish_uci_format_info_string(message_ptr, message_len) orelse return;
    defer c.free(@ptrCast(formatted));
    const line = std.mem.span(formatted);
    uci_output.printLine(line.ptr, line.len);
}

// REPORT-12 TU=0: the ss_ search-emit/thread bridges. Their default bodies read a Worker reference
// slot (threads/tt/manager are pointers stored at worker+offset) and call a native target. Ported
// native — reusing graph_layout.worker_off (the same offsets the native search already reads) and
// the native pv driver / threadpool fns. Legacy keeps the C++ Worker-method versions.
fn workerRefPtr(worker: *anyopaque, offset: usize) ?*anyopaque {
    const slot: *const ?*anyopaque = @ptrCast(@alignCast(@as([*]u8, @ptrCast(worker)) + offset));
    return slot.*;
}
fn workerRootDepth(worker: *anyopaque) c_int {
    const p: *const c_int = @ptrCast(@alignCast(@as([*]u8, @ptrCast(worker)) + graph_layout.worker_off.root_depth));
    return p.*;
}
// ss_threads_start / ss_wait_finished relocated into position.zig (M16.7): the driver
// drives the native thread pool directly (native_thread search job is a fn-pointer).
// emit_pv / search_id_pv PV-emit wrappers relocated into position.zig (M16.7).
// REPORT-12 TU=0: threadpool_wait_thread forwards to the native single-thread wait (the pool holds
// native Threads, so the C++ wait_on_thread would lock them as C++ Threads). Pure native forward.
// threadpool wait-thread bridge removed (M16.7): consumers call thread.waitThread directly.
// REPORT-12 TU=0: SharedState.sharedHistories (a reference) is the 4th pointer field of the native
// SharedState struct (shared_state.zig: options/threads/tt/shared_histories/network), i.e. offset 24.
// &ref in C++ yielded that stored pointer; read it directly and clear the native SharedHistoriesMap.
fn sharedStateClearHistories(shared_state: *const anyopaque) callconv(.c) void {
    const shared_histories_off: usize = 3 * @sizeOf(usize);
    const slot: *const *anyopaque = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(shared_state)) + shared_histories_off));
    engine_port.sharedHistoriesClear(slot.*);
}
// insert_history: single-node default never binds (do_bind always 0, numa_config unused) — insert
// directly into the native SharedHistoriesMap reached via the offset-24 shared_histories pointer.
fn sharedStateInsertHistory(shared_state: *const anyopaque, numa_config: *const anyopaque, numa_index: usize, size: usize, do_bind: u8) callconv(.c) void {
    _ = numa_config;
    _ = do_bind;
    const slot: *const *anyopaque = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(shared_state)) + 3 * @sizeOf(usize)));
    engine_port.sharedHistoriesInsert(slot.*, numa_index, size);
}
// REPORT-12 TU=0: with NNUE_EMBEDDING_OFF the embedded net is the 1-byte {0x0} stub (network.cpp);
// loadNetworkBytes fails on it and falls back to the on-disk EvalFile (bench validates the file net).
// Native default-only stub matching that — ByteView{ptr,len} matches the network.zig extern struct ABI.
const NetByteView = extern struct { ptr: [*]const u8, len: usize };
const embedded_nnue_stub = [_]u8{0};
// REPORT-12 TU=0: mark_initialized / set_loaded_state dual-wrote the C++ Network's EvalFile state only
// "to keep the C++ oracle in sync" (network.zig). In the default build there is no C++ eval reading
// it — the native load owns the state (nn_current/nn_description, set just before these calls) — so
// they are no-ops, avoiding the frozen Network cast. Legacy keeps the real NetworkBridgeAccess writes.
fn networkSetLoadedState(network: *anyopaque, current_name_ptr: [*]const u8, current_name_len: usize, description_ptr: [*]const u8, description_len: usize) callconv(.c) void {
    _ = network;
    _ = current_name_ptr;
    _ = current_name_len;
    _ = description_ptr;
    _ = description_len;
}
// REPORT-12 TU=0: set_listener_mode's default body just mirrors the quiet flag into the native flag
// the native emit reads (the C++ listener installs are legacy-only after Step A). Pure forward.
// uci listener/quiet mode: uci.zig calls uci_output.setQuietMode directly (M16.7).
// numa_set_from_string no-op stub moved into numa.zig (M16.7).
// REPORT-12 TU=0: ss_npmsec_advance (nodestime path). The only C++ bit was tm->advance_nodes_time(x),
// which is just `availableNodes = max(0, availableNodes - x)`. Inlined natively via pinned offsets
// (manager->tm@8, tm.availableNodes@+24; limits.inc pinned in B4a; side via the native helper).
// ssNpmsecAdvance: relocated into position.zig (M16.7).
// REPORT-12 TU=0: the movepick history snapshot. Stats::data() returns the object's flat storage,
// which is the object's own address — so each history pointer IS its .data() (identity). The snapshot
// is just: copy the table pointers + the 6 continuation pointers + the shared-history pawn table/mask
// (SharedHistories pawnHistory@16 {size@0,data@8}, pawnHistSizeMinus1@40 — pinned in B4c). Bench/movepick
// exercises this every node, so search-parity + oracle-parity certify the offsets.
// REPORT-12 TU=0: the read-blob fns parse weights into the C++ Network only in the legacy oracle; the
// default build serves weights from native storage and discards these results, so they are no-ops.
fn networkLayerReadBlob(network: *anyopaque, bucket: usize, data_ptr: [*]const u8, data_len: usize) callconv(.c) usize {
    _ = network;
    _ = bucket;
    _ = data_ptr;
    _ = data_len;
    return 0;
}
// REPORT-12 TU=0: native engine teardown (no C++ ~UCIEngine). Free the states slot, join+free the
// native Threads + null the pool's threads vector, then free the heap members. All three are native.
extern fn zfish_native_threadpool_clear(pool: *anyopaque) void;
fn uciEngineDestructAt(storage: *anyopaque) callconv(.c) void {
    zfish_engine_release_pending_state_slot(native_engine.NativeEngine.fromPtr(storage).statesSlotPtr());
    zfish_native_threadpool_clear(engineThreadsPtr(storage));
    zfishNativeEngineDestructMembers(storage);
}

// Allocate the UCI score text for a raw value: classify (VALUE_TB_WIN_IN_MAX_PLY=
// 31507, VALUE_TB=31753, VALUE_MATE=32000), then map to the cp/tb/mate formatter
// exactly as the C++ Score visit. Caller frees via c_allocator.

// Windows steady clock (M-PORT): QueryPerformanceCounter is the monotonic high-res
// counter; ticks/QueryPerformanceFrequency gives seconds. Declared here (not in
// std.os.windows) and only referenced on the Windows branch of zfishNow.

// M-FINAL: zfish_now ported native (default-only). Stockfish::now() = steady_clock ms;
// CLOCK_MONOTONIC is the POSIX steady_clock (QPC on Windows). now() is used only for
// elapsed-time (the goldens are fixed depth/nodes, so the absolute value isn't gated —
// only monotonicity). Ported across the owned OSes (M-PORT).

fn optInt(name: []const u8) c_int {
    return option_port.zfish_optmodel_int_by_name(name.ptr, name.len);
}

// M-FINAL (option readers): the OptionsMap["..."] readers ported to native-model reads.
// The native OptionsModel (option.zig) is the default-build write-authority shadow —
// every option is registered at OptionsMap::add and re-published on setoption — so reading
// it by name is equivalent to the C++ OptionsMap operator[] (oracle-parity default==legacy
// guards this; bench gates Hash/Threads since they size the TT / thread pool). Default-only
// exports (comptime block below); the legacy oracle keeps the C++ OptionsMap reads. The
// `options`/`shared_state` pointer args are unused (the model is a process-global).
fn zfishSharedStateThreadsValue(shared_state_ptr: *const anyopaque) callconv(.c) usize {
    _ = shared_state_ptr;
    return @intCast(optInt("Threads"));
}
fn zfishOptionsSyzygyProbeLimit(options_ptr: *const anyopaque) callconv(.c) c_int {
    _ = options_ptr;
    return optInt("SyzygyProbeLimit");
}

// M-FINAL (string-option readers): the OptionsMap[] string reads via the native model.
fn optStr(name: []const u8) []const u8 {
    var len: usize = 0;
    const p = option_port.zfish_optmodel_string_by_name(name.ptr, name.len, &len);
    return p[0..len];
}
// Duplicate the model's string value into a malloc'd C string the Zig caller frees with
// std.c.free — identical to the C++ alloc_c_string (std::malloc) the callers expected, so
// the malloc/free pairing is preserved (no valgrind allocator-boundary mismatch).
fn dupOptCString(name: []const u8) ?[*:0]u8 {
    const s = optStr(name);
    const buf = std.c.malloc(s.len + 1) orelse return null;
    const dst: [*]u8 = @ptrCast(buf);
    @memcpy(dst[0..s.len], s);
    dst[s.len] = 0;
    return @ptrCast(dst);
}
fn zfishEngineEvalfileText(engine_ptr: *const anyopaque) callconv(.c) ?[*:0]u8 {
    _ = engine_ptr;
    return dupOptCString("EvalFile");
}

// M-FINAL: tt clear/resize/hashfull ported to the native tt ops (tt.zig). The engine tt is the
// native side-allocated buffer (M1; tt_off: cluster_count@0, table@8, generation8@16); the
// native resize/clear (threaded parallel zero) + hashfull already exist and are the same code
// the live search uses. Default-only; the legacy oracle keeps the C++ TranspositionTable methods.
fn zfishEngineTtClear(tt_ptr: *anyopaque, threads: *anyopaque) callconv(.c) void {
    const tp = graph_layout.TranspositionTable.fromPtr(tt_ptr);
    tt_port.clearState(tp.table, tp.cluster_count, &tp.generation8, threads);
}
// tt-hashfull engine reader moved into engine.zig (M16.7).

// M-FINAL / M-SM: native SearchManager construction + native Worker teardown — cracks the
// SearchManager virtual-dtor wall. The C++ make_unique<Search::SearchManager>() and ~Worker's
// `delete manager` (virtual dispatch through the SearchManager vtable) are the ONLY things
// forcing that vtable to stay. Replace them natively:
//   * make: a raw search_manager_size buffer (operator new, so a matching operator delete frees
//     it valgrind-clean), zeroed — the manager's data fields are written by the native reset
//     shims (smReset*) + tm_init before every search (the C++ ctor left them uninitialized
//     too), and updates@112 is set to the engine UpdateContext for the main thread. No vtable,
//     no ctor; check_time is dead and pv() is native, so the vtable is never dispatched.
//   * destroy: free the rootMoves vector buffer + the manager by offset, then return the
//     large-page block. accumulatorStack/refreshTable are POD std::array members (trivial
//     dtors), so manager + rootMoves are the ONLY heap ~Worker freed — this reproduces it
//     without the virtual `delete manager`. Default-only; the legacy oracle keeps the real
//     C++ SearchManager + ~Worker. See [[frozen-header-wall-blocks-member-cuts]].
fn zfishMakeSearchManager(update_context: ?*const anyopaque, is_main: u8) callconv(.c) ?*anyopaque {
    const buf = zfishOperatorNew(graph_layout.search_manager_size) orelse return null;
    const bytes: [*]u8 = @ptrCast(buf);
    @memset(bytes[0..graph_layout.search_manager_size], 0);
    if (is_main != 0) {
        graph_layout.SearchManager.fromPtr(@ptrCast(bytes)).updates = update_context;
    }
    return buf;
}
fn zfishNativeWorkerDestroy(worker: ?*anyopaque) callconv(.c) void {
    const w = worker orelse return;
    const base: [*]u8 = @ptrCast(w);
    // rootMoves vector buffer (begin @ root_moves+0); operator new'd by zfish_worker_set_root_moves.
    const rm_begin: *?*anyopaque = @ptrCast(@alignCast(base + graph_layout.worker_off.root_moves));
    if (rm_begin.*) |b| zfishOperatorDelete(b);
    // SearchManager buffer (operator new'd by zfishMakeSearchManager above).
    const mgr: *?*anyopaque = @ptrCast(@alignCast(base + graph_layout.worker_off.manager));
    if (mgr.*) |m| zfishOperatorDelete(m);
    memory_port.alignedLargePagesFree(w);
}

// REPORT-12 TU=0: option registration — format the default string per kind (check→"true"/"false",
// spin→decimal, button→"", string→bytes), exactly as the C++ Option ctor / default_str would, then
// register into the native option model (option_port.zfish_optmodel_add). No C++ Option / OptionsMap is built in
// the default build; the engine pointer + callback_kind are unused (the model derives the on-change
// callback from the option name). Legacy keeps the C++ OptionsMap registration.
// engine option registration moved into engine.zig (M16.7); initBody builds the
// native OptionsModel there via the option module directly.

// REPORT-12 TU=0: native Search::RootMoves (= libc++ std::vector<RootMove>) builder/destroyer. The C++
// build a heap std::vector<RootMove> via make_unique + reserve + emplace_back. Reproduced natively: the
// 24-byte libc++ vector header {begin@0, end@8, cap@16} (operator_new'd, matching make_unique's new) wraps
// an operator_new'd element buffer of count*root_move_size (552) RootMoves (matching the vector's reserve).
// Each element is the RootMove(Move) ctor (pv={raw_move}, member-init defaults: scores=-VALUE_INFINITE,
// mean²=-VALUE_INFINITE², the rest 0/false) plus tbRank/tbScore. destroy mirrors `delete vec`:
// operator_delete the element buffer (~vector) then the header. All allocs route through zfish_operator_new
// /_delete, so the alloc/free family stays matched (valgrind-clean). count==0 (mate/stalemate root) → {0,0,0}.
const RankedRootMove = extern struct {
    raw_move: u16,
    reserved: u16,
    tb_rank: c_int,
    tb_score: c_int,
};
// RootMoves ranked builder/destroyer relocated into thread.zig (M16.7).

// REPORT-12 TU=0: the `go` command owner. Builds a Search::LimitsType (120-byte POD; layout per
// graph_layout.limits_off — searchmoves std::vector<std::string>@0, then the TimePoints/ints/nodes/
// ponderMode) and hands it to the native go path (zfish_engine_go_owner → goEngine → start_thinking,
// which deep-copies it into each worker). The searchmoves vector is the libc++ {begin@0,end@8,cap@16}
// header over an operator_new'd buffer of count 24-byte SSO std::strings (UCI moves are short, always
// SSO: byte0=size<<1, chars@+1). start_thinking copies limits synchronously, so the local searchmoves
// buffer is freed right after (matching the C++ stack LimitsType destruction). Gate-covered by
// search-modes (searchmoves filtering) + teardown (the searchmoves vector alloc/free under valgrind).
const ParsedLimits = extern struct {
    wtime: i64,
    btime: i64,
    winc: i64,
    binc: i64,
    movestogo: c_int,
    depth: c_int,
    mate: c_int,
    perft: c_int,
    infinite: c_int,
    movetime: i64,
    nodes: u64,
    ponder_mode: u8,
    searchmoves: ?[*:0]u8,
};
fn goParsedOwner(engine_ptr: *anyopaque, parsed: ParsedLimits) callconv(.c) void {
    var limits: graph_layout.LimitsType = std.mem.zeroes(graph_layout.LimitsType);
    const base: [*]u8 = @ptrCast(&limits);
    // Capture the search start as early as possible -- upstream UCIEngine::parse_limits
    // sets `limits.startTime = now()` first thing. TimeManagement::init copies it into
    // tm.startTime, and the info-line elapsed is `now() - tm.startTime`. Left unset (0),
    // that elapsed reads as now()-0 (~machine uptime), which is why the `info ... time`
    // /`nps` fields were bogus while the bench's own Total-time summary was correct.
    // Depth/node-limited searches never consult startTime for stopping, so bench node
    // count / signature is unaffected; only the reported time/nps become correct.
    limits.start_time = clock.now();
    limits.time[0] = parsed.wtime;
    limits.time[1] = parsed.btime;
    limits.inc[0] = parsed.winc;
    limits.inc[1] = parsed.binc;
    limits.movestogo = parsed.movestogo;
    limits.depth = parsed.depth;
    limits.mate = parsed.mate;
    limits.perft = parsed.perft;
    limits.infinite = if (parsed.infinite != 0) 1 else 0;
    limits.movetime = parsed.movetime;
    limits.nodes = parsed.nodes;
    limits.ponder_mode = parsed.ponder_mode;

    // searchmoves std::vector<std::string> @ offset 0.
    var sm_elems: ?*anyopaque = null;
    if (parsed.searchmoves) |sm_ptr| {
        const sm = std.mem.span(sm_ptr);
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, sm, '\n');
        while (it.next()) |tok| {
            if (tok.len != 0) count += 1;
        }
        if (count != 0) {
            const nbytes = count * 24; // count * sizeof(std::string)
            const elems = zfishOperatorNew(nbytes) orelse @panic("searchmoves: operator new failed");
            const ebase: [*]u8 = @ptrCast(elems);
            @memset(ebase[0..nbytes], 0);
            var i: usize = 0;
            it = std.mem.splitScalar(u8, sm, '\n');
            while (it.next()) |tok| {
                if (tok.len == 0) continue;
                const slot = ebase + i * 24;
                slot[0] = @intCast(tok.len << 1); // libc++ SSO size byte
                @memcpy(slot[1 .. 1 + tok.len], tok);
                i += 1;
            }
            @as(*usize, @ptrCast(@alignCast(base))).* = @intFromPtr(elems); // begin
            @as(*usize, @ptrCast(@alignCast(base + 8))).* = @intFromPtr(elems) + nbytes; // end
            @as(*usize, @ptrCast(@alignCast(base + 16))).* = @intFromPtr(elems) + nbytes; // cap
            sm_elems = elems;
        }
    }

    zfish_engine_go_owner(engine_ptr, @ptrCast(base));
    // start_thinking deep-copied limits into the workers, so free our searchmoves buffer now (the moves
    // are SSO, so no per-string heap to free — just the element buffer).
    if (sm_elems) |e| zfishOperatorDelete(e);
}

// REPORT-12 TU=0: `go perft N` root divide. Reads the engine FEN, builds a scratch Position + StateInfo
// (operator_new'd, max-aligned; the C++ used stack p/st), set()s it, generates the legal root moves
// natively, and per move runs the native perft subtree (do_move_state / perft_subtree / undo_move),
// printing "<move>: <count>" then the "Nodes searched: N" total — byte-exact (the `perft` parity
// harness diffs the divide output). Output routes through zfish_uci_print_line (the coordinated
// sync_cout wrapper). Gate-covered by the `perft` check (CPW positions + a chess960 castling position).
fn perftOwner(engine_ptr: *anyopaque, depth: c_int) callconv(.c) u64 {
    zfish_engine_verify_network_method(engine_ptr);
    const fen_ptr = zfish_engine_fen(native_engine.NativeEngine.fromPtr(@constCast(engine_ptr)).positionPtr()) orelse @panic("perft: null fen");
    const fen = std.mem.span(fen_ptr);
    const c960_name: []const u8 = "UCI_Chess960";
    const chess960 = option_port.zfish_optmodel_int_by_name(c960_name.ptr, c960_name.len) != 0;

    const p = zfishOperatorNew(graph_layout.position_size) orelse @panic("perft: position alloc");
    const st = zfishOperatorNew(graph_layout.state_info_size) orelse @panic("perft: state alloc");
    @memset(@as([*]u8, @ptrCast(p))[0..graph_layout.position_size], 0);
    @memset(@as([*]u8, @ptrCast(st))[0..graph_layout.state_info_size], 0);
    if (zfish_position_set_method(p, fen.ptr, fen.len, if (chess960) @as(u8, 1) else 0, st, graph_layout.position_size, graph_layout.state_info_size)) |msg| std.c.free(msg);

    var moves: [256]u16 = undefined;
    const count = movegen_port.generateLegal(p, &moves);
    var nodes: u64 = 0;
    var mbuf: [5]u8 = undefined;
    var line: [64]u8 = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const m = moves[i];
        var cnt: u64 = undefined;
        if (depth <= 1) {
            cnt = 1;
            nodes += 1;
        } else {
            var si: [graph_layout.state_info_size]u8 align(16) = undefined;
            position_port.doMoveState(p, m, @ptrCast(&si));
            cnt = zfish_perft_subtree(p, depth - 1);
            nodes += cnt;
            zfish_position_undo_move_method(p, m);
        }
        const txt = uci_move_port.renderMoveText(&mbuf, m, chess960);
        const out = std.fmt.bufPrint(&line, "{s}: {d}", .{ txt, cnt }) catch unreachable;
        uci_output.printLine(out.ptr, out.len);
    }

    zfishOperatorDelete(p);
    zfishOperatorDelete(st);
    std.c.free(@ptrCast(fen_ptr));

    var nbuf: [48]u8 = undefined;
    const nout = std.fmt.bufPrint(&nbuf, "\nNodes searched: {d}\n", .{nodes}) catch unreachable;
    uci_output.printLine(nout.ptr, nout.len);
    return nodes;
}

// REPORT-12 TU=0: the setoption owner. Waits for any search to finish, applies the assignment to the
// native option model, fires the on-change callback exactly as the C++ Option operator= would (spin/check
// relay the int + its decimal text, string relays the current value, button relays nothing), and routes
// the result + the "No such option" error through zfish_uci_print_line (the coordinated sync_cout wrapper).
// Mirrors UCIEngine::print_info_string: split the message on '\n', skip whitespace-only lines, prefix each
// with "info string ". Output is un-gated by the automated gates (no gate diffs setoption stdout), so it is
// verified by a manual default-vs-legacy stdout diff (setoption Threads numa emit / EvalFile / bad name).
// ModelSetResult lives in the option module now (option_port.ModelSetResult) -- M16.5.
// REPORT-12 TU=0: ThreadPool::boundThreadToNumaNode (std::vector<NumaIndex/size_t>) assign, reproduced on
// the native ThreadPool footprint vector {begin@40,end@48,cap@56}. count==0 (single-node — the only gated
// path) clears (end=begin). count>0 (multi-node) frees the old element buffer and operator_new's a fresh
// count*8 one (matched alloc/free family). Single-node never allocs, so valgrind/teardown stay clean.
fn threadpoolBoundNodesAssign(pool_ptr: *anyopaque, nodes: ?[*]const usize, count: usize) callconv(.c) void {
    const base: [*]u8 = @ptrCast(pool_ptr);
    const begin_p: *usize = @ptrCast(@alignCast(base + 40));
    const end_p: *usize = @ptrCast(@alignCast(base + 48));
    const cap_p: *usize = @ptrCast(@alignCast(base + 56));
    if (nodes == null or count == 0) {
        end_p.* = begin_p.*; // clear (keep capacity)
        return;
    }
    if (begin_p.* != 0) zfishOperatorDelete(@ptrFromInt(begin_p.*));
    const nbytes = count * 8;
    const buf = zfishOperatorNew(nbytes) orelse @panic("bound_nodes_assign: operator new failed");
    const dst: [*]usize = @ptrCast(@alignCast(buf));
    const src = nodes.?;
    var i: usize = 0;
    while (i < count) : (i += 1) dst[i] = src[i];
    begin_p.* = @intFromPtr(buf);
    end_p.* = @intFromPtr(buf) + nbytes;
    cap_p.* = @intFromPtr(buf) + nbytes;
}

// REPORT-12 TU=0: the native ThreadBuilder callback — the LAST C++ piece of the construction cluster
// (make_search_manager, worker_construct_full, shared_histories_at are all already native). Reads the
// native SharedState's five reference referents by offset (options@0, threads@8, tt@16, sharedHistories@24,
// network@32 — shared_state.zig's 40-byte bundle), mints the SearchManager, large-page-allocs + natively
// constructs the Worker, and writes the Worker at thread+8 (the worker@8 layout contract). Single-node
// host: numaIndex 0, idxInNuma == idx, totalNuma == ctx.total. The C++ &ss.<member> (a reference member's
// referent address) equals the native field VALUE, so the field values are passed straight through.
const WorkerBuildCtx = extern struct {
    shared_state: ?*anyopaque,
    update_context: ?*const anyopaque,
    total: usize,
};
extern fn zfish_worker_construct_full(buf: ?*anyopaque, shared_history: usize, options: usize, threads: usize, tt: usize, network: usize, manager: usize, thread_idx: usize, numa_thread_idx: usize, numa_total: usize, numa_access_token: usize) void;
fn nativeWorkerBuild(ctx_ptr: ?*anyopaque, idx: usize, thread: *anyopaque) callconv(.c) void {
    const ctx: *WorkerBuildCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const ss: [*]u8 = @ptrCast(ctx.shared_state.?);
    const ss_options = @as(*usize, @ptrCast(@alignCast(ss + 0))).*;
    const ss_threads = @as(*usize, @ptrCast(@alignCast(ss + 8))).*;
    const ss_tt = @as(*usize, @ptrCast(@alignCast(ss + 16))).*;
    const ss_shared_hist = @as(*usize, @ptrCast(@alignCast(ss + 24))).*;
    const ss_network = @as(*usize, @ptrCast(@alignCast(ss + 32))).*;
    const manager = zfishMakeSearchManager(ctx.update_context, if (idx == 0) @as(u8, 1) else 0) orelse
        @panic("native worker build: SearchManager OOM");
    const raw = memory_port.alignedLargePagesAlloc(graph_layout.worker_size) orelse
        @panic("native worker build: large-page OOM");
    const shared_history = engine_port.sharedHistoriesAt(@ptrFromInt(ss_shared_hist), 0);
    zfish_worker_construct_full(
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

// M-FINAL (construction-crack pattern): `new Position()` / `delete` ported native. Position
// has a defaulted trivial ctor and owns no heap (board arrays + pointers; StateListPtr is a
// type alias, not a member), so value-init == a zeroed position_size (1032B) block. operator
// new/delete keeps the alloc/free family matched (the trace_pos / pool throwaway Position is
// destroyed via zfish_position_destroy). Default-only; legacy keeps new/delete Position.
fn zfishPositionDestroy(pos: ?*anyopaque) callconv(.c) void {
    if (pos) |p| zfishOperatorDelete(p);
}

// AccumulatorCaches create (`new AccumulatorCaches(network)`) moved into engine.zig (M16.7),
// now that the native FT biases pointer lives in the network module.

// M-FINAL (construction-crack + init): `new AccumulatorStack()` / `delete` ported native.
// AccumulatorStack is POD (std::array members + a `size = 1` default member init), so value-init
// == a zeroed accumulator_stack_size block with size set to 1. zfish_accumulator_stack_reset on
// a zeroed buffer is exactly that (it sets size=1 and clears state-0's already-zero computed/diff
// fields), so it reproduces the ctor state. operator new/delete keeps the family matched.
fn zfishEngineAccumulatorStackDestroy(stack: ?*anyopaque) callconv(.c) void {
    if (stack) |buf| zfishOperatorDelete(buf);
}

// zfish_search_cb_tt_context: hand the native search the worker TT's cluster
// array, cluster count, and generation, resolved by offset. Bridge-only symbol.
// zfish_search_cb_tt_context: relocated into position.zig (M16.7).

// SearchManager::check_time inputs, snapshotted once per search tree. Mirrors the
// position.zig SearchTimeState exactly: live (mutable) fields are pointers; the
// fixed-per-search fields are values; calls_cnt is null off the main thread.
const ZfishSearchTimeState = extern struct {
    calls_cnt: ?*c_int,
    stop_write: ?*u8,
    ponder: ?*const u8,
    stop_on_ponderhit: ?*const u8,
    tm_start_time: i64,
    tm_maximum_time: i64,
    lim_nodes: u64,
    lim_movetime: i64,
    tm_use_nodes_time: u8,
    use_time_management: u8,
};

// zfish_search_cb_worker_state: the once-per-search snapshot the ported search
// runs on. Hands the search stable pointers to the Worker's live members (nodes,
// optimism, nmpMinPly/selDepth/rootDepth/rootDelta, lastIterationPV, pvIdx/pvLast,
// bestMoveChanges, the accumulator stack + refresh cache), the reductions table
// and rootMoves array bases, the shared threads.stop flag, and -- on the main
// thread -- the SearchManager/TimeManagement/LimitsType time-control inputs. All
// reads are by offset and identical across builds, so this is a plain export.
// zfish_search_cb_worker_state: relocated into position.zig (M16.7, network cycle broken).

// zfish_ss_prologue: the per-search reset the ported search runs before iterative
// deepening. Resets the worker's AccumulatorStack to one cleared slot (the native
// stackReset -- the same clearComputed/zeroDiff/size primitives the push/pop path
// already proves byte-exact) and clears lastIterationPV (PVMoves::clear == length
// 0). Touches no options, so it is identical across builds: plain export.
// zfish_ss_prologue: relocated into position.zig (M16.7).

// zfish_ss_tm_init: the per-search TimeManagement::init + TT::new_search the main
// thread runs at search start. The time-control math is already native
// (timeman_port.init); this reproduces the C++ wrapper: build the input from the
// worker's limits/rootPos and the manager's tm + originalTimeAdjust, read the
// nodestime/Move Overhead/Ponder options, then write the outputs back into tm,
// the manager, and limits, and bump the TT generation (new_search).
//
// The option reads hit the native model, which is empty in the legacy oracle, so
// this is gated default-only: the legacy build keeps the C++ tm.init that reads
// the C++ OptionsMap. See [[native-optionsmodel-default-only]]. Bench has no time
// control (time[us] == 0), so the path is gate-exercised every search but the
// timeman output is inert; correctness of the writeback is still proven because
// the native and C++ inputs match field-for-field in the default build.
// zfish_ss_tm_init: relocated into position.zig (M16.7).

// zfish_thread_fill_summary: snapshot the per-thread voting inputs natively
// (replacing the C++ forwarder to fill_thread_summary). worker = the Thread's
// LargePagePtr at thread_off.worker; the fields are rootMoves[0].pv[0]/score/
// bound-flags/pv-size and rootDepth -- the same values the native search<Root>
// already reads. Gated default-only: src/thread.cpp also defines this symbol, so
// the legacy oracle uses that (see [[legacy-seam-blocks-zig-export-flips]]).

// zfish_ss_get_best_thread: return the worker of the vote-winning thread. The
// voting itself is already native (thread_port.bestThreadIndex, the same routine
// the C++ ThreadPool::get_best_thread inline bounces to in both builds), so this
// just calls it directly and resolves threads[idx]->worker by offset -- a pure
// forwarding-hop removal, identical to the previous threads.get_best_thread()->
// worker.get(). Only reached with Threads>1 (bench is single-thread, so not
// gate-exercised) but behaviourally unchanged. Plain export, no gating.
// zfish_ss_get_best_thread: relocated into position.zig via the thread_vote leaf (M16.7).

// zfish_search_id_collect_bmc: relocated into position.zig (M16.7).

// Matches the bridge ZfishIdState struct (iterative-deepening snapshot).
const ZfishIdState = extern struct {
    root_pos: ?*anyopaque,
    root_moves: ?*anyopaque,
    pv_idx: ?*anyopaque,
    pv_last: ?*anyopaque,
    sel_depth: ?*anyopaque,
    root_depth: ?*anyopaque,
    root_delta: ?*anyopaque,
    optimism: ?*anyopaque,
    nodes: ?*const anyopaque,
    stop: ?*anyopaque,
    increase_depth: ?*anyopaque,
    stop_on_ponderhit: ?*anyopaque,
    ponder: ?*const anyopaque,
    iter_value: ?*anyopaque,
    previous_time_reduction: ?*anyopaque,
    last_iter_pv: ?*anyopaque,
    root_moves_count: usize,
    thread_idx: usize,
    threads_size: usize,
    multipv_option: usize,
    tm_optimum: i64,
    tm_maximum: i64,
    tm_start_time: i64,
    limits_depth: c_int,
    limits_mate: c_int,
    best_previous_score: c_int,
    best_previous_average_score: c_int,
    skill_level: f64,
    is_main: u8,
    use_time_management: u8,
    tm_use_nodes_time: u8,
    skill_enabled: u8,
};

// Skill(level, elo) from the C++ ctor: a set UCI_Elo maps to a clamped [0,19]
// level; otherwise the level is the Skill Level option. enabled() == level < 20.

// zfish_search_id_state: snapshot the iterative-deepening state for the native
// search. Worker/pool member pointers and scalars are taken by offset; the main
// thread also exposes its SearchManager fields and TimeManagement optimum/maximum/
// startTime/useNodesTime (simple getters). skill_level/enabled and multipv read
// the native option model, which is only populated in the default build, so this
// is gated default-only (the legacy oracle keeps the C++ body that reads the C++
// OptionsMap). See the gated @export below.
// zfish_search_id_state + skillLevel: relocated into position.zig (M16.7).

// Matches the bridge ZfishSsCtx struct.
const ZfishSsCtx = extern struct {
    is_mainthread: u8,
    root_moves_empty: u8,
    npmsec: u8,
    limits_depth: i32,
    skill_enabled: u8,
};

// zfish_ss_context: snapshot the search-start flags. skill_enabled mirrors
// Skill(level, elo).enabled() == level < 20: a set UCI_Elo (via UCI_LimitStrength)
// always clamps level to <= 19 (enabled), otherwise Skill Level < 20. Bridge-only.
// zfish_ss_context: relocated into position.zig (M16.7).

// Matches the bridge ZfishPvContext struct filled for the native pv driver.
const ZfishPvContext = extern struct {
    manager: ?*anyopaque,
    worker: ?*anyopaque,
    root_moves: ?*const anyopaque,
    root_moves_count: usize,
    multipv: usize,
    show_wdl: u8,
    chess960: u8,
    nodes: u64,
    tb_hits: u64,
    hashfull: c_int,
    elapsed_ms: u64,
};

// zfish_search_cb_pv_context: snapshot the per-pv() values the native info driver
// needs. rootMoves data()/size() from the worker's vector, MultiPV/UCI_ShowWDL
// from the native option model, chess960 from rootPos, the node/tb-hit aggregates
// from the pool, TT hashfull natively, and elapsed = max(1, now - tm.startTime)
// (which only feeds the gate-stripped time/nps fields). Bridge-only, no gating.
// zfish_search_cb_pv_context: relocated into position.zig (M16.7).

// zfish_search_cb_root_on_iter: on the main thread, print "info depth D currmove
// X currmovenumber N" (N = move_count + pvIdx). The native search only calls this
// past 10M nodes; quiet mode is a no-op. Bridge-only symbol, no gating.

// zfish_ss_emit_no_moves: at a checkmated/stalemated root, print "info depth 0
// score <fmt>" (mate 0 when in check, else cp 0) followed by "bestmove (none)".
// Quiet mode is a no-op. Bridge-only symbol, no gating.

// zfish_ss_emit_bestmove: in interactive mode prints "bestmove X[ ponder Y]"
// where X = best->rootMoves[0].pv[0] and Y = pv[1] (when pv length > 1), both
// rendered with worker->rootPos chess960. Quiet mode is a no-op, matching the
// C++ no-op onBestmove listener. Bridge-only symbol, no gating.

// zfish_ss_set_stop: worker->threads.stop = true. Plain byte store, matching the
// gate-verified native tpSetStopFlag (bridge-only symbol, no gating).
// zfish_ss_set_stop: relocated into position.zig (M16.7).

// zfish_ss_should_busywait: !threads.stop && (manager->ponder || limits.infinite).
// Resolves the pool stop byte, the worker's manager ponder flag, and the limits
// infinite int by offset (bridge-only symbol, no gating).
// zfish_ss_should_busywait: relocated into position.zig (M16.7).

// UCIEngine::cli accessors (bridge-only). cli is a CommandLine {int argc;
// char** argv} at uci_engine_off.cli_argc; arg_at bounds-checks against argc and
// loads the i-th argv pointer, returning null out of range (as the C++ did).
pub export fn zfish_uci_cli_argc(uci: *const anyopaque) c_int {
    return nativeEng(@constCast(uci)).cli_argc;
}
pub export fn zfish_uci_cli_arg_at(uci: *const anyopaque, index: c_int) ?[*:0]const u8 {
    const e = nativeEng(@constCast(uci));
    if (index < 0 or index >= e.cli_argc) return null;
    const argv = e.cli_argv orelse return null;
    return argv[@intCast(index)];
}

// ThreadPool::boundThreadToNumaNode accessors (bridge-only). The member is a
// std::vector<size_t> at bound_nodes_begin; count is the byte span / 8 and
// at(i) loads the i-th element from the begin pointer.
pub export fn zfish_threadpool_bound_node_at(pool: *const anyopaque, index: usize) usize {
    const begin = graph_layout.ThreadPool.fromPtr(@constCast(pool)).bound_begin;
    return @as(*const usize, @ptrFromInt(begin + index * @sizeOf(usize))).*;
}

// NumaConfig::num_numa_nodes() == nodes.size() (bridge-only symbol, no gating).
// nodes is a std::vector<std::set<CpuIndex>> at offset 0; size is the byte span
// divided by the 48-byte std::set element.
// numa node-count / cpus-in-node single-node stubs moved into numa.zig (M16.7);
// engine.zig and thread.zig call the numa module directly.

pub fn zfish_engine_init_body(engine: *anyopaque) void {
    return engine_port.initBody(engine);
}

// M-FINAL cutover (NATIVE_ENGINE_CUTOVER.md): native engine container construct/destruct.
// Default-only (the legacy oracle keeps the inline C++ UCIEngine + its ctor/dtor; these
// reference the default-only zfish_member_* heap helpers). Exported + compiled now but
// NOT yet on the live path (zfish_uci_engine_construct_at still builds the C++ UCIEngine);
// the flip commit swaps main()'s allocation + the member accessors to these.
fn zfishNativeEngineConstructMembers(buf: *anyopaque, argv0: [*:0]const u8) callconv(.c) bool {
    return native_engine.constructMembers(buf, argv0);
}
fn zfishNativeEngineSetCli(buf: *anyopaque, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) void {
    native_engine.setCli(buf, argc, argv);
}
// REPORT-12 TU=0: native engine construction (no C++ UCIEngine ctor). Verify the object-graph
// footprint, build the heap members + inline sub-objects, store argc/argv, then run init_body
// (register options, set start position, size threads) — the same post-member work the UCIEngine ctor
// body did. The C++ default also ran Tune::init(engine_options()), but Tune (SPSA) is INERT in a release
// build (no live TUNE() macros → instance().list is empty → init/read are empty loops; only the unused
// static Tune::options is set), so it is dropped here. oracle-parity proves dropping it is behavior-neutral.
fn nativeUciEngineConstructAt(storage: *anyopaque, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) void {
    graph_layout.zfish_graph_verify_layouts();
    if (!zfishNativeEngineConstructMembers(storage, argv[0]))
        @panic("native engine construct: member allocation failed");
    zfishNativeEngineSetCli(storage, argc, argv);
    zfish_engine_init_body(storage);
}
fn zfishNativeEngineDestructMembers(buf: *anyopaque) callconv(.c) void {
    native_engine.destructMembers(buf);
}

pub fn zfish_engine_option_on_change(
    engine: *anyopaque,
    callback_kind: u8,
    value_ptr: [*]const u8,
    value_len: usize,
    int_value: c_int,
) ?[*:0]u8 {
    return engine_port.optionOnChange(engine, callback_kind, value_ptr, value_len, int_value);
}

pub fn zfish_engine_release_pending_state_slot(states_slot: *anyopaque) void {
    return engine_port.releasePendingStateSlot(states_slot);
}

pub fn zfish_engine_fen(pos: *const anyopaque) ?[*:0]u8 {
    return engine_port.fen(pos);
}




pub fn zfish_engine_verify_network_method(engine_ptr: *const anyopaque) void {
    return engine_port.verifyNetwork(engine_ptr);
}



pub fn zfish_engine_go_owner(engine_ptr: *anyopaque, limits_ptr: *const anyopaque) void {
    return engine_port.goEngine(engine_ptr, limits_ptr);
}



// numa-config-from-option is applied inside engine.zig directly (M16.7).





// M-FINAL cutover: native NumaConfig::to_string() for the single-node default build. Enumerates
// the process CPU affinity (sched_getaffinity — the same STARTUP_PROCESSOR_AFFINITY from_system
// reads) and formats it as the comma-separated CPU ranges to_string emits for ONE node (e.g.
// "0-7"). Multi-node numa support was dropped (single-node decision), so there is no ":" node
// separator. Replaces the C++ NumaReplicationContext::get_numa_config().to_string() in default.
//
// M-PORT: sched_getaffinity/cpu_set_t are Linux-only. macOS/Windows have no per-thread affinity
// mask in the same shape, and the single-node default engine only needs "which CPUs may I run
// on"; there std.Thread.getCpuCount() gives the online count and the set is the contiguous range
// 0..n-1, formatted identically ("0-7", or "0" for one CPU).





pub export fn zfish_engine_load_network_owner(
    engine_ptr: *anyopaque,
    file_ptr: [*]const u8,
    file_len: usize,
) void {
    return engine_port.loadNetworkEngine(engine_ptr, file_ptr[0..file_len]);
}

pub export fn zfish_engine_save_network_owner(
    engine_ptr: *anyopaque,
    has_filename: u8,
    filename_ptr: [*]const u8,
    filename_len: usize,
) void {
    return engine_port.saveNetworkEngine(
        engine_ptr,
        if (has_filename != 0) filename_ptr[0..filename_len] else null,
    );
}




const AccumulatorStackPushPair = extern struct {
    first: *anyopaque,
    second: *anyopaque,
};

// network load/verify/trace-evaluate/evaluate + the FT/layer weight storage and
// transform all live in network.zig (M16.7). The network->position cycle is now
// broken (network reads Position's side-to-move/board via the leaf graph_layout),
// so position calls network.evaluate directly -- no main bridge remains.

pub fn zfish_tt_generation_next(curr_generation: u8) u8 {
    return tt_port.generationNext(curr_generation);
}

pub fn zfish_tt_hashfull(
    clusters: [*]const tt_port.TtCluster,
    cluster_count: usize,
    generation: u8,
    max_age: c_int,
) c_int {
    return tt_port.hashfull(clusters, cluster_count, generation, max_age);
}

// setoption parsing: uci.zig calls option.parseSetOption directly (M16.7).

pub fn zfish_uci_format_info_string(
    input_ptr: [*]const u8,
    input_len: usize,
) ?[*:0]u8 {
    return uci_port.formatInfoString(input_ptr[0..input_len]);
}

// uci_to_cp: engine calls the leaf uci_wdl.toCp directly (M16.7).

pub fn zfish_half_ka_make_index(
    params: nnue_feature_port.HalfThreatParams,
) u32 {
    return nnue_feature_port.halfMakeIndex(params);
}

pub fn zfish_half_ka_append_changed(
    perspective: u8,
    king_square: u8,
    diff: nnue_feature_port.HalfDiff,
) nnue_feature_port.HalfAppendResult {
    return nnue_feature_port.halfAppendChanged(perspective, king_square, diff);
}

// full-threats append (changed/active): nnue_accumulator.zig calls nnue_feature directly (M16.7).

// (zfish_aligned_large_pages_alloc/free and zfish_has_large_pages retired -- M16.5:
// tt/position/misc now call the `memory` module directly instead of via these C-ABI exports.)

// Last-reported "nodes searched" counter for the UCI info path. Owned in Zig;
// the C++ engine update listeners publish into it via zfish_set_last_nodes_searched.
// last-nodes-searched atomic + accessors moved into the uci_output leaf (M16.7);
// uci.zig reads it directly.




