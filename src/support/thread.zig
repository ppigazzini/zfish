const std = @import("std");
const graph_layout = @import("graph_layout");
const native_hooks = @import("native_hooks");
const c = @import("libc");
const position_snapshot = @import("position_snapshot");
const position_port = @import("position");
const uci_move = @import("uci_move");
const movegen_port = @import("movegen");
const tablebase = @import("tablebase");
const option_port = @import("option");
const state_list = @import("state_list");
const numa = @import("numa");

// Zig-owned thread job runner (engine-graph reimplementation). Verified by its
// own concurrency tests; compile-checked here until wired into construction.
pub const thread_runtime = @import("thread_runtime");
// Native thread runtime (the live vehicle): native Threads + ThreadPool replacing
// the C++ Thread/std::thread idle_loop.
const native_thread = @import("native_thread");
const native_threadpool = @import("native_threadpool.zig");

// Reinterpret a pool thread slot (NativeThread*) for the sync handshake.
inline fn nt(thread: *anyopaque) *native_thread.NativeThread {
    return @ptrCast(@alignCast(thread));
}

// Thread sync handshake -> the native runtime.
inline fn threadWaitFinished(thread: *anyopaque) void {
    nt(thread).waitForSearchFinished();
}
inline fn threadStartSearching(thread: *anyopaque) void {
    native_thread.startSearching(nt(thread));
}
inline fn threadClearWorker(thread: *anyopaque) void {
    native_thread.clearWorker(nt(thread));
}
inline fn threadRunJob(thread: *anyopaque, job: ThreadCallback, ctx: ?*anyopaque) void {
    nt(thread).startJob(job, ctx);
}
// Native read of LimitsType::searchmoves[index]. The exe is built by Zig (bundled libc++), so
// std::string is the LIBC++ layout: sizeof 24; short/SSO has byte0 = (size<<1) (low bit 0) with the
// chars inline at +1; long has byte0 low bit 1, size@+8, data ptr@+16. searchmoves is the leading
// std::vector<std::string> (limits+0, {_M_start@0}); element stride is sizeof(std::string)=24.
// Read-only (no allocation). Gate-verified by search-modes (exercises `go ... searchmoves`).
inline fn limitsSearchmoveText(limits: *const anyopaque, index: usize) ByteView {
    // searchmoves is no longer at LimitsType offset 0 (native struct); read its
    // libc++ vector begin pointer through the typed field.
    const lt = graph_layout.LimitsType.fromPtr(@constCast(limits));
    const vec_begin = lt.searchmoves[0]; // typed [3]usize header {begin, end, cap}
    const str_ptr = vec_begin + index * 24;
    const b0 = @as(*const u8, @ptrFromInt(str_ptr)).*;
    if (b0 & 1 == 0) return .{ .ptr = @ptrFromInt(str_ptr + 1), .len = b0 >> 1 };
    const size = @as(*const usize, @ptrFromInt(str_ptr + 8)).*;
    const data = @as(*const usize, @ptrFromInt(str_ptr + 16)).*;
    return .{ .ptr = @ptrFromInt(data), .len = size };
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

const value_draw: c_int = 0;
const value_mate: c_int = 32000;
const value_none: c_int = 32002;
const value_infinite: c_int = 32001;
const value_tb_win_in_max_ply: c_int = 31507;
const value_tb_loss_in_max_ply: c_int = -31507;
const max_ply: c_int = 246;
const max_dtz: c_int = 1 << 18;
const square_count: usize = 64;
const white_oo: u8 = 1;
const white_ooo: u8 = 2;
const black_oo: u8 = 4;
const black_ooo: u8 = 8;
const pawn_value: c_int = 208;
const probe_fail: c_int = 0;
const wdl_loss: c_int = -2;
const wdl_blessed_loss: c_int = -1;
const wdl_draw: c_int = 0;
const wdl_cursed_win: c_int = 1;
const wdl_win: c_int = 2;

const wdl_to_rank = [_]c_int{
    -max_dtz,
    -max_dtz + 101,
    0,
    max_dtz - 101,
    max_dtz,
};

const wdl_to_value = [_]c_int{
    -value_mate + max_ply + 1,
    value_draw - 2,
    value_draw,
    value_draw + 2,
    value_mate - max_ply - 1,
};

pub const ByteView = struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub const TbConfig = struct {
    cardinality: c_int,
    root_in_tb: u8,
    use_rule50: u8,
    probe_depth: c_int,
};

const TablebaseProbe = tablebase.ProbeResult;

const RankedRootMove = struct {
    raw_move: u16,
    reserved: u16,
    tb_rank: c_int,
    tb_score: c_int,
};

const RootSetupInput = struct {
    limits: *const anyopaque,
    root_moves: *const anyopaque,
    fen_ptr: [*]const u8,
    fen_len: usize,
    setup_state: *const anyopaque,
    chess960: u8,
    tb_config: TbConfig,
};

const RootSetupContext = struct {
    thread: *anyopaque,
    input: RootSetupInput,
};

const PositionSnapshot = position_snapshot.PositionSnapshot;

const numa_policy_none: u8 = 0;
const numa_policy_auto: u8 = 1;

// Native Search::RootMoves (= the C++ std::vector<RootMove>) builder/destroyer, relocated
// from main.zig (M16.7). Lays out a 24-byte {begin,end,cap} header over a `count`-element
// RootMove array (stride graph_layout.root_move_size == 552), each element zeroed then
// initialised to the RootMove default (scores at -VALUE_INFINITE) with the ranked tb fields
// and the single-move PV. Matches the vector the worker binds by reference.
fn rootMovesCreateRanked(items: [*]const RankedRootMove, count: usize) ?*anyopaque {
    const header = std.c.malloc(24) orelse return null;
    const hdr: [*]usize = @ptrCast(@alignCast(header));
    if (count == 0) {
        hdr[0] = 0;
        hdr[1] = 0;
        hdr[2] = 0;
        return header;
    }
    const stride = graph_layout.root_move_size; // 552
    const bytes = count * stride;
    const elems = std.c.malloc(bytes) orelse return null;
    const base: [*]u8 = @ptrCast(elems);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const rm: *position_port.RootMove = @ptrCast(@alignCast(base + i * stride));
        @memset(@as([*]u8, @ptrCast(rm))[0..stride], 0);
        rm.score = -value_infinite;
        rm.previous_score = -value_infinite;
        rm.average_score = -value_infinite;
        rm.mean_squared_score = -(value_infinite * value_infinite);
        rm.uci_score = -value_infinite;
        rm.tb_rank = items[i].tb_rank;
        rm.tb_score = items[i].tb_score;
        rm.pv.moves[0] = items[i].raw_move;
        rm.pv.length = 1;
    }
    hdr[0] = @intFromPtr(elems);
    hdr[1] = @intFromPtr(elems) + bytes;
    hdr[2] = @intFromPtr(elems) + bytes;
    return header;
}
fn rootMovesDestroy(ptr: ?*anyopaque) void {
    const p = ptr orelse return;
    const hdr: [*]usize = @ptrCast(@alignCast(p));
    if (hdr[0] != 0) std.c.free(@ptrFromInt(hdr[0]));
    std.c.free(p);
}

// Copy the LimitsType POD fields (everything but the leading searchmoves vector) into
// the worker's limits member. LimitsType is a native struct now, so copy by field rather
// than a byte range; searchmoves is deliberately left as the worker's own (the search
// reads the worker's, always empty on the gated single-node path).
fn workerSetLimits(thread: *anyopaque, src_limits: *const anyopaque) void {
    const worker = graph_layout.Thread.fromPtr(thread).worker;
    const dst = &graph_layout.WorkerLayout.fromAddr(worker).limits;
    const src = graph_layout.LimitsType.fromPtr(@constCast(src_limits));
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

// libc++ vector<RootMove> copy-assign into the worker's rootMoves member:
// reuse the existing buffer when its capacity fits, else operator-new a
// fresh one and free the old — exactly like assigning an element range.
fn workerSetRootMoves(thread: *anyopaque, src_rm: *const anyopaque) void {
    // worker@8, then the rootMoves vector object {begin[0],end[1],cap[2]}.
    const worker = graph_layout.Thread.fromPtr(thread).worker;
    const dst = &graph_layout.WorkerLayout.fromAddr(worker).root_moves;
    const dst_begin: *usize = &dst[0];
    const dst_end: *usize = &dst[1];
    const dst_cap: *usize = &dst[2];

    // src_rm is a libc++ vector<RootMove> header {begin,end,cap}.
    const src = @as(*const [3]usize, @ptrCast(@alignCast(src_rm)));
    const src_begin = src[0];
    const src_end = src[1];
    const byte_count = src_end - src_begin;

    if (byte_count == 0) {
        dst_end.* = dst_begin.*;
        return;
    }

    const cap_bytes = if (dst_begin.* != 0) dst_cap.* - dst_begin.* else 0;
    if (dst_begin.* != 0 and cap_bytes >= byte_count) {
        @memcpy(
            @as([*]u8, @ptrFromInt(dst_begin.*))[0..byte_count],
            @as([*]const u8, @ptrFromInt(src_begin))[0..byte_count],
        );
        dst_end.* = dst_begin.* + byte_count;
    } else {
        const new_buf = @intFromPtr(std.c.malloc(byte_count) orelse @panic("set_root_moves: OOM"));
        @memcpy(
            @as([*]u8, @ptrFromInt(new_buf))[0..byte_count],
            @as([*]const u8, @ptrFromInt(src_begin))[0..byte_count],
        );
        if (dst_begin.* != 0) std.c.free(@ptrFromInt(dst_begin.*));
        dst_begin.* = new_buf;
        dst_end.* = new_buf + byte_count;
        dst_cap.* = new_buf + byte_count;
    }
}
// Assign the pool's boundThreadToNumaNode vector (native graph_layout.ThreadPool field).
fn boundNodesAssign(pool_ptr: *anyopaque, nodes: ?[*]const usize, count: usize) void {
    const tp = graph_layout.ThreadPool.fromPtr(pool_ptr);
    if (nodes == null or count == 0) {
        tp.bound_end = tp.bound_begin; // clear (keep capacity)
        return;
    }
    if (tp.bound_begin != 0) c.free(@ptrFromInt(tp.bound_begin));
    const nbytes = count * 8;
    const buf = c.malloc(nbytes) orelse @panic("bound_nodes_assign: malloc failed");
    const dst: [*]usize = @ptrCast(@alignCast(buf));
    const src = nodes.?;
    var i: usize = 0;
    while (i < count) : (i += 1) dst[i] = src[i];
    tp.bound_begin = @intFromPtr(buf);
    tp.bound_end = @intFromPtr(buf) + nbytes;
    tp.bound_cap = @intFromPtr(buf) + nbytes;
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

fn waitMainThread(pool: *anyopaque) void {
    if (graph_layout.ThreadPool.fromPtr(@constCast(pool)).numThreads() == 0)
        return;

    threadWaitFinished(graph_layout.ThreadPool.fromPtr(@constCast(pool)).threadAtPtr(0));
}

fn buildRootFen(pos: *const position_port.Position) ?[*:0]u8 {
    var pieces: [square_count]u8 = undefined;
    position_port.accumulatorSnapshot(pos, &pieces);
    const snapshot = loadPositionSnapshot(pos);

    return position_port.formatFen(
        @ptrCast(&pieces),
        snapshot.side_to_move,
        snapshot.is_chess960,
        snapshot.castling_rights,
        snapshot.castling_rook_square[white_oo],
        snapshot.castling_rook_square[white_ooo],
        snapshot.castling_rook_square[black_oo],
        snapshot.castling_rook_square[black_ooo],
        snapshot.ep_square,
        snapshot.rule50_count,
        snapshot.game_ply,
    );
}

const ScratchPosition = struct {
    pos: *position_port.Position,
    storage: *anyopaque,

    fn init(root_fen: []const u8, chess960: u8) ScratchPosition {
        const pos: *position_port.Position = @ptrCast(@alignCast(position_port.create() orelse @panic("OOM")));
        errdefer position_port.destroy(pos);

        const storage = state_list.storageCreate() orelse @panic("OOM");
        errdefer state_list.storageDestroy(storage);

        var scratch = ScratchPosition{ .pos = pos, .storage = storage };
        scratch.reset(root_fen, chess960);
        return scratch;
    }

    fn deinit(self: *ScratchPosition) void {
        state_list.storageDestroy(self.storage);
        position_port.destroy(self.pos);
    }

    fn reset(self: *ScratchPosition, root_fen: []const u8, chess960: u8) void {
        const root_state = state_list.storageReset(self.storage);
        if (position_port.setPositionState(self.pos, root_fen.ptr, root_fen.len, chess960, root_state)) |err| {
            defer c.free(@ptrCast(err));
            @panic("scratch position set failed");
        }
    }

    fn doMove(self: *ScratchPosition, raw_move: u16) void {
        const next_state = state_list.storagePush(self.storage);
        position_port.doMoveState(self.pos, raw_move, next_state);
    }
};

fn countPieces(pos: *const position_port.Position) usize {
    var pieces: [square_count]u8 = undefined;
    position_port.accumulatorSnapshot(pos, &pieces);

    var count: usize = 0;
    for (pieces) |piece| {
        if (piece != 0)
            count += 1;
    }
    return count;
}

fn loadTbConfig(options: *const anyopaque, pos: *const position_port.Position) TbConfig {
    _ = options; // syzygy options now read from the native option model, not this pointer
    const snapshot = loadPositionSnapshot(pos);
    var config = TbConfig{
        .cardinality = option_port.syzygyProbeLimit(),
        .root_in_tb = 0,
        .use_rule50 = @intFromBool(option_port.syzygy50MoveRule()),
        .probe_depth = option_port.syzygyProbeDepth(),
    };

    const max_cardinality: c_int = @intCast(tablebase.maxCardinality());
    if (config.cardinality > max_cardinality) {
        config.cardinality = max_cardinality;
        config.probe_depth = 0;
    }

    if (config.cardinality < @as(c_int, @intCast(countPieces(pos))) or
        snapshot.castling_rights != 0)
    {
        config.cardinality = 0;
    }

    return config;
}

fn probePosition(pos: *const position_port.Position) TablebaseProbe {
    const snapshot = loadPositionSnapshot(pos);
    const fen_ptr = buildRootFen(pos) orelse @panic("OOM");
    defer c.free(@ptrCast(fen_ptr));
    const fen_text = std.mem.span(fen_ptr);
    return tablebase.probeFen(fen_text.ptr, fen_text.len, snapshot.is_chess960);
}

fn dtzBeforeZeroing(wdl: c_int) c_int {
    return switch (wdl) {
        wdl_win => 1,
        wdl_cursed_win => 101,
        wdl_blessed_loss => -101,
        wdl_loss => -1,
        else => 0,
    };
}

const DtzRankResult = enum {
    success,
    fallback_to_wdl,
};

fn rankRootMovesDtz(
    root_fen: []const u8,
    chess960: u8,
    rule50: bool,
    root_rule50: c_int,
    root_has_repeated: bool,
    ranked_moves: []RankedRootMove,
) DtzRankResult {
    var scratch = ScratchPosition.init(root_fen, chess960);
    defer scratch.deinit();

    const bound: c_int = if (rule50) @divTrunc(max_dtz, 2) - 100 else 1;

    for (ranked_moves) |*ranked_move| {
        scratch.reset(root_fen, chess960);
        scratch.doMove(ranked_move.raw_move);

        var dtz: c_int = 0;
        if (loadPositionSnapshot(scratch.pos).rule50_count == 0) {
            const probe = probePosition(scratch.pos);
            if (probe.wdl_state == probe_fail)
                return .fallback_to_wdl;
            dtz = dtzBeforeZeroing(-probe.wdl);
        } else if ((rule50 and position_port.isDraw(scratch.pos, 1)) or
            position_port.isRepetition(scratch.pos, 1))
        {
            dtz = 0;
        } else {
            const probe = probePosition(scratch.pos);
            if (probe.dtz_state == probe_fail)
                return .fallback_to_wdl;

            dtz = -probe.dtz;
            dtz = if (dtz > 0)
                dtz + 1
            else if (dtz < 0)
                dtz - 1
            else
                0;
        }

        if (loadPositionSnapshot(scratch.pos).checkers != 0 and dtz == 2) {
            var legal_moves: [256]u16 = undefined;
            if (movegen_port.generateLegal(scratch.pos, legal_moves[0..].ptr) == 0)
                dtz = 1;
        }

        const rank: c_int = if (dtz > 0)
            if (dtz + root_rule50 <= 99 and !root_has_repeated)
                max_dtz - dtz
            else
                @divTrunc(max_dtz, 2) - (dtz + root_rule50)
        else if (dtz < 0)
            if (-dtz * 2 + root_rule50 < 100)
                -max_dtz - dtz
            else
                -@divTrunc(max_dtz, 2) + (-dtz + root_rule50)
        else
            0;

        ranked_move.tb_rank = rank;
        ranked_move.tb_score = if (rank >= bound)
            value_mate - max_ply - 1
        else if (rank > 0)
            @divTrunc(@max(@as(c_int, 3), rank - (@divTrunc(max_dtz, 2) - 200)) * pawn_value, 200)
        else if (rank == 0)
            value_draw
        else if (rank > -bound)
            @divTrunc(@min(@as(c_int, -3), rank + (@divTrunc(max_dtz, 2) - 200)) * pawn_value, 200)
        else
            -value_mate + max_ply + 1;
    }

    return .success;
}

fn loadPositionSnapshot(pos: *const position_port.Position) PositionSnapshot {
    var snapshot = std.mem.zeroes(PositionSnapshot);
    position_port.fillSnapshot(pos, &snapshot);
    return snapshot;
}

fn rankRootMovesWdl(
    root_fen: []const u8,
    chess960: u8,
    rule50: bool,
    ranked_moves: []RankedRootMove,
) bool {
    var scratch = ScratchPosition.init(root_fen, chess960);
    defer scratch.deinit();

    for (ranked_moves) |*ranked_move| {
        scratch.reset(root_fen, chess960);
        scratch.doMove(ranked_move.raw_move);

        var wdl: c_int = undefined;
        if (position_port.isDraw(scratch.pos, 1)) {
            wdl = wdl_draw;
        } else {
            const probe = probePosition(scratch.pos);
            if (probe.wdl_state == probe_fail)
                return false;
            wdl = -probe.wdl;
        }

        ranked_move.tb_rank = wdl_to_rank[@intCast(wdl + 2)];

        var score_wdl = wdl;
        if (!rule50) {
            score_wdl = if (wdl > 0)
                wdl_win
            else if (wdl < 0)
                wdl_loss
            else
                wdl_draw;
        }
        ranked_move.tb_score = wdl_to_value[@intCast(score_wdl + 2)];
    }

    return true;
}

fn stableSortRankedMovesByTbRank(ranked_moves: []RankedRootMove) void {
    var index: usize = 1;
    while (index < ranked_moves.len) : (index += 1) {
        const current = ranked_moves[index];
        var insert_at = index;

        while (insert_at > 0 and ranked_moves[insert_at - 1].tb_rank < current.tb_rank) : (insert_at -= 1) {
            ranked_moves[insert_at] = ranked_moves[insert_at - 1];
        }
        ranked_moves[insert_at] = current;
    }
}

fn buildRootMoves(
    allocator: std.mem.Allocator,
    options: *const anyopaque,
    pos: *const position_port.Position,
    root_fen: []const u8,
    chess960: u8,
    move_raws: []const u16,
) struct { root_moves: *anyopaque, tb_config: TbConfig } {
    const ranked_moves = allocator.alloc(RankedRootMove, move_raws.len) catch @panic("OOM");
    defer allocator.free(ranked_moves);

    for (move_raws, 0..) |raw_move, index| {
        ranked_moves[index] = .{
            .raw_move = raw_move,
            .reserved = 0,
            .tb_rank = 0,
            .tb_score = 0,
        };
    }

    var tb_config = loadTbConfig(options, pos);
    var dtz_available = true;

    if (tb_config.cardinality != 0) {
        const root_snapshot = loadPositionSnapshot(pos);
        const dtz_result = rankRootMovesDtz(
            root_fen,
            chess960,
            tb_config.use_rule50 != 0,
            root_snapshot.rule50_count,
            position_port.hasRepeated(pos),
            ranked_moves,
        );

        switch (dtz_result) {
            .success => tb_config.root_in_tb = 1,
            .fallback_to_wdl => {
                dtz_available = false;
                if (rankRootMovesWdl(root_fen, chess960, tb_config.use_rule50 != 0, ranked_moves)) {
                    tb_config.root_in_tb = 1;
                }
            },
        }
    }

    if (tb_config.root_in_tb != 0) {
        stableSortRankedMovesByTbRank(ranked_moves);
        if (dtz_available or ranked_moves[0].tb_score <= value_draw)
            tb_config.cardinality = 0;
    }

    const root_moves = rootMovesCreateRanked(ranked_moves.ptr, ranked_moves.len) orelse
        @panic("OOM: native RootMoves allocation");
    return .{
        .root_moves = root_moves,
        .tb_config = tb_config,
    };
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
) void {
    if (pool.numThreads() > 0) {
        waitMainThread(pool);
        native_threadpool.clear(pool);
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
    const bound_nodes = allocator.alloc(usize, requested) catch @panic("OOM");
    defer allocator.free(bound_nodes);

    if (do_bind) {
        _ = numa.distributeThreadsAmongNodes(
            numa_config,
            requested,
            bound_nodes.ptr,
        );
        boundNodesAssign(pool, bound_nodes.ptr, requested);
    } else {
        boundNodesAssign(pool, null, 0);
    }

    const node_count = @max(numa.configNodeCount(numa_config), @as(usize, 1));
    const threads_per_node = allocator.alloc(usize, node_count) catch @panic("OOM");
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

    native_hooks.shared_state_clear_histories.?(shared_state);

    var node_index: usize = 0;
    while (node_index < node_count) : (node_index += 1) {
        const count = threads_per_node[node_index];
        if (count != 0) {
            native_hooks.shared_state_insert_history.?(
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
    native_threadpool.set(
        pool,
        @constCast(shared_state),
        update_context,
        requested,
    );

    clear(pool);
    waitMainThread(pool);

    // Harness H4: prove the freshly (re)configured pool matches the Zig model of
    // the ThreadPool/Thread graph -- stop/increaseDepth zeroed, threads vector
    // sized == requested, boundThreadToNumaNode sized as bound, each Thread's
    // Worker slot bound. Read-only; panics on drift.
    native_hooks.verify_thread_graph.?(pool, requested, if (do_bind) requested else 0);
}

// The search-driver entry native_thread invokes as each thread's search job. Set
// as a function pointer (M16.7) so native_thread need not import position.
fn workerSearchEntry(ctx: ?*anyopaque) void {
    position_port.workerStartSearching(ctx);
}

pub fn startThinking(
    pool: *graph_layout.ThreadPool,
    options: *const anyopaque,
    pos: *position_port.Position,
    limits: *const anyopaque,
    states_slot: *anyopaque,
) void {
    native_thread.searchEntry = &workerSearchEntry;
    waitMainThread(pool);
    const tp = pool;
    if (tp.mainManager()) |m| {
        m.setStopOnPonderhit(false);
        m.setPonder(graph_layout.LimitsType.fromPtr(@constCast(limits)).ponderMode());
    }
    tp.setStop(false);
    tp.setIncreaseDepth(true);

    if (native_hooks.pending_states_available.?(states_slot) != 0) {
        if (native_hooks.handoff_pending_states.?(pool, states_slot) == 0)
            @panic("failed to hand off pending setup states");
    } else {
        native_hooks.setup_states_adopt_from_slot.?(pool, states_slot);
        if (!pool.hasSetupStates())
            @panic("missing setup states");
    }

    const setup_state = native_hooks.setup_state_back.?(pool) orelse
        @panic("missing setup state");

    var legal_move_buffer: [256]u16 = undefined;
    const legal_move_count = movegen_port.generateLegal(pos, legal_move_buffer[0..].ptr);
    const legal_moves = legal_move_buffer[0..legal_move_count];
    const none_raw = uci_move.noneRaw();

    var selected_moves = std.ArrayList(u16).empty;
    defer selected_moves.deinit(std.heap.c_allocator);

    const searchmove_count = graph_layout.LimitsType.fromPtr(@constCast(limits)).searchmoveCount();
    var index: usize = 0;
    while (index < searchmove_count) : (index += 1) {
        const move_text = limitsSearchmoveText(limits, index);
        const text_ptr = move_text.ptr orelse continue;
        const move_raw = uci_move.toMoveRaw(pos, text_ptr[0..move_text.len]);
        if (move_raw != none_raw and containsMove(legal_moves, move_raw)) {
            selected_moves.append(std.heap.c_allocator, move_raw) catch @panic("OOM");
        }
    }

    if (selected_moves.items.len == 0) {
        selected_moves.appendSlice(std.heap.c_allocator, legal_moves) catch @panic("OOM");
    }

    const root_fen = buildRootFen(pos) orelse @panic("OOM");
    defer c.free(@ptrCast(root_fen));
    const root_fen_text = std.mem.span(root_fen);
    const chess960 = loadPositionSnapshot(pos).is_chess960;
    const root_setup = buildRootMoves(
        std.heap.c_allocator,
        options,
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
    const root_setup_contexts = allocator.alloc(RootSetupContext, thread_count) catch @panic("OOM");
    defer allocator.free(root_setup_contexts);

    index = 0;
    while (index < thread_count) : (index += 1) {
        const thread = pool.threadAtPtr(index);
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
        const thread = pool.threadAtPtr(index);
        threadWaitFinished(thread);
    }

    const main_thread = pool.threadAtPtr(0);
    threadStartSearching(main_thread);
}

pub fn clear(pool: *anyopaque) void {
    const thread_count = graph_layout.ThreadPool.fromPtr(@constCast(pool)).numThreads();
    if (thread_count == 0) {
        return;
    }

    var index: usize = 0;
    while (index < thread_count) : (index += 1) {
        threadClearWorker(graph_layout.ThreadPool.fromPtr(@constCast(pool)).threadAtPtr(index));
    }

    index = 0;
    while (index < thread_count) : (index += 1) {
        threadWaitFinished(graph_layout.ThreadPool.fromPtr(@constCast(pool)).threadAtPtr(index));
    }

    if (graph_layout.ThreadPool.fromPtr(pool).mainManager()) |m| {
        m.resetBestPreviousAverageScore();
        m.resetPreviousTimeReduction();
        m.resetCallsCount();
        m.resetBestPreviousScore();
        m.resetOriginalTimeAdjust();
        m.clearTimeman();
    }
}

pub fn nodesSearched(pool: *anyopaque) u64 {
    return graph_layout.poolNodesSearched(pool);
}

pub fn tbHits(pool: *anyopaque) u64 {
    return graph_layout.poolTbHits(pool);
}

pub fn startSearching(pool: *anyopaque) void {
    const thread_count = graph_layout.ThreadPool.fromPtr(@constCast(pool)).numThreads();
    var index: usize = 1;
    while (index < thread_count) : (index += 1) {
        threadStartSearching(graph_layout.ThreadPool.fromPtr(@constCast(pool)).threadAtPtr(index));
    }
}

// Wait until one thread's worker finishes its current search (native ThreadPool op).
pub fn waitThread(pool: *anyopaque, thread_id: usize) void {
    native_threadpool.waitThread(pool, thread_id);
}

// Join+free the native Threads and null the pool's threads vector (engine teardown).
// Wraps native_threadpool for main.zig, which doesn't import it directly.
pub fn nativeThreadpoolClear(pool: *anyopaque) void {
    native_threadpool.clear(pool);
}

pub fn waitForSearchFinished(pool: *graph_layout.ThreadPool) void {
    const thread_count = pool.numThreads();
    var index: usize = 1;
    while (index < thread_count) : (index += 1) {
        threadWaitFinished(pool.threadAtPtr(index));
    }
}

pub fn ensureNetworkReplicated(pool: *graph_layout.ThreadPool) void {
    // The NNUE weights are always resident in native storage (no C++ Network numa
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
