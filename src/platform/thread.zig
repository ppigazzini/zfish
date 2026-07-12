const std = @import("std");
const graph_layout = @import("graph_layout");
const native_hooks = @import("native_hooks");
const position_snapshot = @import("position_snapshot");
const position_port = @import("position");
const search_driver = @import("search_driver");
const search_types = @import("search_types");
const uci_move = @import("uci_move");
const movegen_port = @import("movegen");
const tablebase = @import("tablebase");
const option_port = @import("option");
const state_list = @import("state_list");
const PendingStateStorage = state_list.PendingStateStorage;
const numa = @import("numa");

// Zig-owned thread job runner. Verified by its own concurrency tests.
pub const thread_runtime = @import("thread_runtime");
// Native thread runtime: native Threads + ThreadPool driving the idle-loop vehicle.
const search_thread = @import("search_thread");
const thread_pool = @import("thread_pool.zig");
// The root-move builder + Syzygy root-ranking cluster now lives in its own leaf.
// startThinking (and the RootSetupInput it fills) reference these by their old names.
const root_move_build = @import("root_move_build");
const TbConfig = root_move_build.TbConfig;
const buildRootMoves = root_move_build.buildRootMoves;
const buildRootFen = root_move_build.buildRootFen;
const loadPositionSnapshot = root_move_build.loadPositionSnapshot;
const rootMovesDestroy = root_move_build.rootMovesDestroy;

// Reinterpret a pool thread slot (SearchThread*) for the sync handshake.
inline fn nt(thread: *graph_layout.Thread) *search_thread.SearchThread {
    return @ptrCast(@alignCast(thread));
}

// Thread sync handshake -> the native runtime.
inline fn threadWaitFinished(thread: *graph_layout.Thread) void {
    nt(thread).waitForSearchFinished();
}
inline fn threadStartSearching(thread: *graph_layout.Thread) void {
    search_thread.startSearching(nt(thread));
}
inline fn threadClearWorker(thread: *graph_layout.Thread) void {
    search_thread.clearWorker(nt(thread));
}
inline fn threadRunJob(thread: *graph_layout.Thread, job: ThreadCallback, ctx: ?*anyopaque) void {
    nt(thread).startJob(job, ctx);
}
// Read searchmoves[index] as a Zig-owned SearchMoveText record: the libc++
// std::string SSO byte decode is gone -- the length + inline chars are read through
// typed struct fields. The header stays a {begin,end,cap} usize triple, so the
// element pointer is still @ptrFromInt(begin + index*stride), but into Zig-owned
// memory (no foreign-runtime layout). Gate-verified by search-modes.
inline fn limitsSearchmoveText(limits: *const graph_layout.LimitsType, index: usize) ByteView {
    const rec: *const graph_layout.SearchMoveText = &limits.searchmoves[index];
    return .{ .ptr = &rec.text, .len = rec.len };
}
comptime {
    _ = &thread_runtime.ThreadRuntime.start;
    _ = &thread_runtime.ThreadRuntime.runCustomJob;
    _ = &thread_runtime.ThreadRuntime.waitForSearchFinished;
    _ = &thread_runtime.ThreadRuntime.deinit;
    _ = &thread_runtime.ThreadPool.set;
    _ = &thread_runtime.ThreadPool.clear;
    _ = &thread_runtime.ThreadPool.runOnThread;
    _ = &thread_runtime.ThreadPool.waitForSearchFinished;
    _ = &thread_runtime.ThreadPool.setStop;
}

pub const ByteView = struct {
    ptr: ?[*]const u8,
    len: usize,
};

const RootSetupInput = struct {
    limits: *const graph_layout.LimitsType,
    root_moves: []const search_types.RootMove,
    fen_ptr: [*]const u8,
    fen_len: usize,
    setup_state: *const position_port.StateInfo,
    chess960: u8,
    tb_config: TbConfig,
};

const RootSetupContext = struct {
    thread: *graph_layout.Thread,
    input: RootSetupInput,
};

const PositionSnapshot = position_snapshot.PositionSnapshot;

const numa_policy_none: u8 = 0;
const numa_policy_auto: u8 = 1;

// Copy the LimitsType POD fields (everything but the leading searchmoves vector) into
// the worker's limits member. LimitsType is a native struct now, so copy by field rather
// than a byte range; searchmoves is deliberately left as the worker's own (the search
// reads the worker's, always empty on the gated single-node path).
fn workerSetLimits(thread: *graph_layout.Thread, src_limits: *const graph_layout.LimitsType) void {
    const worker = thread.worker.?;
    const dst = &worker.limits;
    const src = src_limits;
    dst.time = src.time;
    dst.inc = src.inc;
    dst.npmsec = src.npmsec;
    dst.movetime = src.movetime;
    dst.start_time = src.start_time;
    dst.movestogo = src.movestogo;
    dst.depth = src.depth;
    dst.mate = src.mate;
    dst.perft = src.perft;
    dst.infinite = src.infinite;
    dst.nodes = src.nodes;
    dst.ponder_mode = src.ponder_mode;
}

// Copy the ranked source RootMoves into the worker's own []RootMove (the DST
// is a typed slice now, unblocked by the proof the WorkerLayout layout is free).
// Reuse the buffer when the count is unchanged (the common re-search case), else free
// and reallocate -- the slice equivalent of the old std::vector copy-assign.
fn workerSetRootMoves(thread: *graph_layout.Thread, src: []const search_types.RootMove) void {
    const worker = thread.worker.?;
    if (src.len == 0) {
        if (worker.root_moves.len != 0) std.heap.c_allocator.free(worker.root_moves);
        worker.root_moves = &[_]search_types.RootMove{};
        return;
    }
    if (worker.root_moves.len != src.len) {
        if (worker.root_moves.len != 0) std.heap.c_allocator.free(worker.root_moves);
        worker.root_moves = std.heap.c_allocator.alloc(search_types.RootMove, src.len) catch @panic("set_root_moves: OOM");
    }
    @memcpy(worker.root_moves, src);
}
const ThreadCallback = *const fn (?*anyopaque) void;

const NumaNodeCallback = *const fn (?*anyopaque) void;

fn applyRootSetup(context_ptr: ?*anyopaque) void {
    const context: *const RootSetupContext = @ptrCast(@alignCast(context_ptr.?));
    // Native LimitsType POD-field copy.
    workerSetLimits(context.thread, context.input.limits);
    // Native vector<RootMove> copy-assign.
    workerSetRootMoves(context.thread, context.input.root_moves);
    if (graph_layout.Worker.fromThread(context.thread)) |w| {
        w.resetRootSetupState();
        const cfg = context.input.tb_config;
        _ = position_port.setPosition(
            w.rootPosPtr(),
            context.input.fen_ptr,
            context.input.fen_len,
            context.input.chess960,
            w.rootStatePtr(),
            graph_layout.position_size,
            graph_layout.state_info_size,
        );
        w.setRootState(context.input.setup_state);
        w.setTbConfig(cfg.cardinality, cfg.root_in_tb != 0, cfg.use_rule50 != 0, cfg.probe_depth);
    }
}

fn waitMainThread(pool: *graph_layout.ThreadPool) void {
    if (pool.numThreads() == 0)
        return;

    threadWaitFinished(pool.threadTyped(0));
}

pub fn nextPowerOfTwo(count: u64) usize {
    if (count <= 1)
        return 1;
    return @as(usize, 2) << @as(u6, @intCast(63 - @clz(count - 1)));
}

pub fn reconfigure(
    pool: *graph_layout.ThreadPool,
    numa_config: *const anyopaque,
    shared_state: *const anyopaque,
    update_context: *const anyopaque,
) !void {
    if (pool.numThreads() > 0) {
        waitMainThread(pool);
        thread_pool.clear(pool);
    }

    const requested = option_port.optionThreads();
    if (requested == 0) {
        return;
    }

    var do_bind = false;
    switch (option_port.numaPolicyMode()) {
        numa_policy_none => do_bind = false,
        numa_policy_auto => do_bind = numa.suggestsBindingThreads(numa_config, requested),
        else => do_bind = true,
    }

    const allocator = std.heap.c_allocator;
    const bound_nodes = try allocator.alloc(usize, requested);
    defer allocator.free(bound_nodes);

    if (do_bind) {
        _ = numa.distributeThreadsAmongNodes(
            numa_config,
            requested,
            bound_nodes.ptr,
        );
        try thread_pool.boundNodesAssign(pool, allocator, bound_nodes);
    } else {
        try thread_pool.boundNodesAssign(pool, allocator, null);
    }

    const node_count = @max(numa.configNodeCount(numa_config), @as(usize, 1));
    const threads_per_node = try allocator.alloc(usize, node_count);
    defer allocator.free(threads_per_node);
    @memset(threads_per_node, 0);

    if (do_bind) {
        var index: usize = 0;
        while (index < requested) : (index += 1) {
            threads_per_node[bound_nodes[index]] += 1;
        }
    } else {
        threads_per_node[0] = requested;
    }

    native_hooks.shared_state_clear_histories(shared_state);

    var node_index: usize = 0;
    while (node_index < node_count) : (node_index += 1) {
        const count = threads_per_node[node_index];
        if (count != 0) {
            native_hooks.shared_state_insert_history(
                shared_state,
                numa_config,
                node_index,
                nextPowerOfTwo(count),
                @intFromBool(do_bind),
            );
        }
    }

    // Build native Threads (idle loop + Worker) into the pool's threads vector via
    // the native ThreadPool. Single-node host (do_bind == false): numaIndex 0,
    // idxInNuma == idx, totalNuma == requested.
    try thread_pool.set(
        pool,
        @constCast(shared_state),
        update_context,
        requested,
    );

    clear(pool);
    waitMainThread(pool);

    // Prove the freshly (re)configured pool matches the Zig model of
    // the ThreadPool/Thread graph -- stop/increaseDepth zeroed, threads vector
    // sized == requested, boundThreadToNumaNode sized as bound, each Thread's
    // Worker slot bound. Read-only; panics on drift.
    native_hooks.verify_thread_graph(pool, requested, if (do_bind) requested else 0);
}

// The search-driver entry search_thread invokes as each thread's search job. Set
// as a function pointer so search_thread need not import position.
fn workerSearchEntry(ctx: ?*anyopaque) void {
    search_driver.workerStartSearching(ctx);
}

pub fn startThinking(
    pool: *graph_layout.ThreadPool,
    pos: *position_port.Position,
    limits: *const graph_layout.LimitsType,
    states_slot: *anyopaque,
) !void {
    search_thread.searchEntry = &workerSearchEntry;
    waitMainThread(pool);
    const tp = pool;
    if (tp.mainManager()) |m| {
        m.setStopOnPonderhit(false);
        m.setPonder(limits.ponderMode());
    }
    tp.setStop(false);
    tp.setIncreaseDepth(true);

    if (native_hooks.pending_states_available(states_slot) != 0) {
        if (native_hooks.handoff_pending_states(pool, states_slot) == 0)
            @panic("failed to hand off pending setup states");
    } else {
        native_hooks.setup_states_adopt_from_slot(pool, states_slot);
        if (!pool.hasSetupStates())
            @panic("missing setup states");
    }

    const setup_state = native_hooks.setup_state_back(pool) orelse
        @panic("missing setup state");

    var legal_move_buffer: [256]u16 = undefined;
    const legal_move_count = movegen_port.generateLegal(pos, legal_move_buffer[0..].ptr);
    const legal_moves = legal_move_buffer[0..legal_move_count];
    const none_raw = uci_move.noneRaw();

    var selected_moves = std.ArrayList(u16).empty;
    defer selected_moves.deinit(std.heap.c_allocator);

    const searchmove_count = limits.searchmoveCount();
    var index: usize = 0;
    while (index < searchmove_count) : (index += 1) {
        const move_text = limitsSearchmoveText(limits, index);
        const text_ptr = move_text.ptr orelse continue;
        const move_raw = uci_move.toMoveRaw(pos, text_ptr[0..move_text.len]);
        if (move_raw != none_raw and containsMove(legal_moves, move_raw)) {
            try selected_moves.append(std.heap.c_allocator, move_raw);
        }
    }

    if (selected_moves.items.len == 0) {
        try selected_moves.appendSlice(std.heap.c_allocator, legal_moves);
    }

    const root_fen = buildRootFen(pos) orelse return error.OutOfMemory;
    defer std.heap.c_allocator.free(std.mem.span(root_fen));
    const root_fen_text = std.mem.span(root_fen);
    const chess960 = loadPositionSnapshot(pos).is_chess960;
    const root_setup = try buildRootMoves(
        std.heap.c_allocator,
        pos,
        root_fen_text,
        chess960,
        selected_moves.items,
    );
    const root_moves = root_setup.root_moves;
    defer rootMovesDestroy(root_moves);
    const tb_config = root_setup.tb_config;
    const thread_count = pool.numThreads();
    const allocator = std.heap.c_allocator;
    const root_setup_contexts = try allocator.alloc(RootSetupContext, thread_count);
    defer allocator.free(root_setup_contexts);

    index = 0;
    while (index < thread_count) : (index += 1) {
        const thread = pool.threadTyped(index);
        root_setup_contexts[index] = .{
            .thread = thread,
            .input = .{
                .limits = limits,
                .root_moves = root_moves,
                .fen_ptr = root_fen,
                .fen_len = root_fen_text.len,
                .setup_state = setup_state,
                .chess960 = chess960,
                .tb_config = tb_config,
            },
        };
        threadRunJob(thread, applyRootSetup, &root_setup_contexts[index]);
    }

    index = 0;
    while (index < thread_count) : (index += 1) {
        const thread = pool.threadTyped(index);
        threadWaitFinished(thread);
    }

    const main_thread = pool.threadTyped(0);
    threadStartSearching(main_thread);
}

pub fn clear(pool: *graph_layout.ThreadPool) void {
    const thread_count = pool.numThreads();
    if (thread_count == 0) {
        return;
    }

    var index: usize = 0;
    while (index < thread_count) : (index += 1) {
        threadClearWorker(pool.threadTyped(index));
    }

    index = 0;
    while (index < thread_count) : (index += 1) {
        threadWaitFinished(pool.threadTyped(index));
    }

    if (pool.mainManager()) |m| {
        m.resetBestPreviousAverageScore();
        m.resetPreviousTimeReduction();
        m.resetCallsCount();
        m.resetBestPreviousScore();
        m.resetOriginalTimeAdjust();
        m.clearTimeman();
    }
}

pub fn nodesSearched(pool: *graph_layout.ThreadPool) u64 {
    return graph_layout.poolNodesSearched(pool);
}

pub fn tbHits(pool: *graph_layout.ThreadPool) u64 {
    return graph_layout.poolTbHits(pool);
}

pub fn startSearching(pool: *graph_layout.ThreadPool) void {
    const thread_count = pool.numThreads();
    var index: usize = 1;
    while (index < thread_count) : (index += 1) {
        threadStartSearching(pool.threadTyped(index));
    }
}

// Wait until one thread's worker finishes its current search (native ThreadPool op).
pub fn waitThread(pool: *graph_layout.ThreadPool, thread_id: usize) void {
    thread_pool.waitThread(pool, thread_id);
}

// Join+free the native Threads and null the pool's threads vector (engine teardown).
// Wraps thread_pool for main.zig, which doesn't import it directly.
pub fn nativeThreadpoolClear(pool: *graph_layout.ThreadPool) void {
    thread_pool.clear(pool);
}

pub fn waitForSearchFinished(pool: *graph_layout.ThreadPool) void {
    const thread_count = pool.numThreads();
    var index: usize = 1;
    while (index < thread_count) : (index += 1) {
        threadWaitFinished(pool.threadTyped(index));
    }
}

pub fn ensureNetworkReplicated(pool: *graph_layout.ThreadPool) void {
    // The NNUE weights are always resident in native storage (no per-node Network
    // replica), so Worker::ensure_network_replicated is a no-op.
    _ = pool;
}

fn containsMove(moves: []const u16, target: u16) bool {
    for (moves) |move_raw| {
        if (move_raw == target) {
            return true;
        }
    }

    return false;
}
