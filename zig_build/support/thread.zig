const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});
const position_snapshot = @import("position_snapshot");
const position_port = @import("position");
const uci_move = @import("uci_move");

// Zig-owned thread job runner (engine-graph reimplementation). Verified by its
// own concurrency tests; compile-checked here until wired into construction.
pub const thread_runtime = @import("thread_runtime.zig");
// Stage-4 native thread runtime (the live vehicle): native Threads + ThreadPool
// replacing the C++ Thread/std::thread idle_loop. The C++ pool/Engine stay, but
// their threads vector now holds native Threads (contents-swap).
const native_thread = @import("native_thread.zig");
const native_threadpool = @import("native_threadpool.zig");

// Reinterpret a pool thread slot (NativeThread*) for the sync handshake.
inline fn nt(thread: *anyopaque) *native_thread.NativeThread {
    return @ptrCast(@alignCast(thread));
}

// Stage-4 per-build vehicle gate. The legacy oracle build keeps the C++ Thread
// vehicle (so the thread.cpp oracle stays comparable); the default build uses the
// native runtime. The `thread` module is shared by both exes, so a comptime flag
// Stage-7: the legacy/default split is now COMPTIME. thread.zig is built per-exe
// (build.zig: thread_module_default/_legacy each import the matching target_flags),
// so legacyBuild() is a compile-time constant and Zig prunes the dead branch -- the
// default exe stops referencing the legacy C++ zfish_thread_* sync wrappers and the
// C++ Thread vehicle (they become #ifdef ZFISH_LEGACY_CPP_TARGET in the bridge). Was
// a runtime extern (zfish_is_legacy_build) only because the module was shared.
const target_flags = @import("target_flags");
inline fn legacyBuild() bool {
    return target_flags.legacy_target;
}
inline fn threadWaitFinished(thread: *anyopaque) void {
    if (legacyBuild()) zfish_thread_wait_for_search_finished(thread) else nt(thread).waitForSearchFinished();
}
inline fn threadStartSearching(thread: *anyopaque) void {
    if (legacyBuild()) zfish_thread_start_searching(thread) else native_thread.startSearching(nt(thread));
}
inline fn threadClearWorker(thread: *anyopaque) void {
    if (legacyBuild()) zfish_thread_clear_worker(thread) else native_thread.clearWorker(nt(thread));
}
inline fn threadRunJob(thread: *anyopaque, job: ThreadCallback, ctx: ?*anyopaque) void {
    if (legacyBuild()) zfish_thread_run_callback(thread, job, ctx) else nt(thread).startJob(job, ctx);
}
// M-FINAL cutover: native read of LimitsType::searchmoves[index] in the default build, dropping the
// C++ zfish_limits_searchmove_text bridge. The default exe is built by Zig (bundled libc++), so
// std::string is the LIBC++ layout: sizeof 24; short/SSO has byte0 = (size<<1) (low bit 0) with the
// chars inline at +1; long has byte0 low bit 1, size@+8, data ptr@+16. searchmoves is the leading
// std::vector<std::string> (limits+0, {_M_start@0}); element stride is sizeof(std::string)=24.
// Read-only (no allocation). Gate-verified by search-modes (exercises `go ... searchmoves`).
inline fn limitsSearchmoveText(limits: *const anyopaque, index: usize) ByteView {
    if (legacyBuild()) return zfish_limits_searchmove_text(limits, index);
    const vec_begin = @as(*const usize, @ptrFromInt(@intFromPtr(limits))).*;
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
const max_thread_summaries: usize = 1024;
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

pub const ThreadSummary = extern struct {
    pv0_raw: u16,
    score_is_bound: u8,
    pv_has_more_than_two: u8,
    score: c_int,
    root_depth: c_int,
};

pub const ByteView = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub const TbConfig = extern struct {
    cardinality: c_int,
    root_in_tb: u8,
    use_rule50: u8,
    probe_depth: c_int,
};

const TablebaseProbe = extern struct {
    available: u8,
    wdl: c_int,
    wdl_state: c_int,
    dtz: c_int,
    dtz_state: c_int,
};

const RankedRootMove = extern struct {
    raw_move: u16,
    reserved: u16,
    tb_rank: c_int,
    tb_score: c_int,
};

const RootSetupInput = extern struct {
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

extern fn zfish_threadpool_set_stop_flag(pool: *anyopaque, stop: u8) void;
extern fn zfish_threadpool_main_manager_set_stop_on_ponderhit(pool: *anyopaque, stop_on_ponderhit: u8) void;
extern fn zfish_threadpool_main_manager_set_ponder(pool: *anyopaque, ponder: u8) void;
extern fn zfish_threadpool_set_increase_depth(pool: *anyopaque, increase_depth: u8) void;
extern fn zfish_threadpool_setup_states_adopt_from_slot(pool: *anyopaque, states_slot: *anyopaque) void;
extern fn zfish_threadpool_has_setup_states(pool: *const anyopaque) u8;
extern fn zfish_threadpool_setup_state_back(pool: *const anyopaque) ?*const anyopaque;
extern fn zfish_engine_pending_states_available(states_slot: *anyopaque) u8;
extern fn zfish_engine_handoff_pending_states(pool: *anyopaque, states_slot: *anyopaque) u8;
extern fn zfish_accumulator_position_snapshot(pos: *const anyopaque, pieces_out: [*]u8) void;
extern fn zfish_movegen_generate_legal(
    pos: *const anyopaque,
    out_moves: [*]u16,
) usize;
extern fn zfish_limits_ponder_mode(limits: *const anyopaque) u8;
extern fn zfish_limits_searchmove_count(limits: *const anyopaque) usize;
extern fn zfish_limits_searchmove_text(limits: *const anyopaque, index: usize) ByteView;
extern fn zfish_position_fill_snapshot(pos: *const anyopaque, out: *PositionSnapshot) void;
extern fn zfish_position_create() ?*anyopaque;
extern fn zfish_position_destroy(pos: ?*anyopaque) void;
extern fn zfish_root_moves_create_ranked(items: [*]const RankedRootMove, count: usize) *anyopaque;
extern fn zfish_root_moves_destroy(root_moves: *anyopaque) void;
extern fn zfish_options_syzygy_50_move_rule(options: *const anyopaque) u8;
extern fn zfish_options_syzygy_probe_depth(options: *const anyopaque) c_int;
extern fn zfish_options_syzygy_probe_limit(options: *const anyopaque) c_int;
extern fn zfish_tbprobe_max_cardinality() usize;
extern fn zfish_tbprobe_probe_fen(
    fen_ptr: [*]const u8,
    fen_len: usize,
    chess960: u8,
) TablebaseProbe;
extern fn zfish_engine_state_list_storage_create() ?*anyopaque;
extern fn zfish_engine_state_list_storage_destroy(storage: ?*anyopaque) void;
extern fn zfish_engine_state_list_storage_reset(storage: *anyopaque) *anyopaque;
extern fn zfish_engine_state_list_storage_push(storage: *anyopaque) *anyopaque;
extern fn zfish_position_set_state(
    pos: *anyopaque,
    fen_ptr: [*]const u8,
    fen_len: usize,
    chess960_enabled: u8,
    state: *anyopaque,
) ?[*:0]u8;
extern fn zfish_position_do_move_state(pos: *anyopaque, move_raw: u16, state: *anyopaque) void;
extern fn zfish_threadpool_thread_count(pool: *const anyopaque) usize;
extern fn zfish_threadpool_thread_at(pool: *anyopaque, index: usize) *anyopaque;
extern fn zfish_threadpool_main_manager_reset_best_previous_average_score(pool: *anyopaque) void;
extern fn zfish_threadpool_main_manager_reset_previous_time_reduction(pool: *anyopaque) void;
extern fn zfish_threadpool_main_manager_reset_calls_count(pool: *anyopaque) void;
extern fn zfish_threadpool_main_manager_reset_best_previous_score(pool: *anyopaque) void;
extern fn zfish_threadpool_main_manager_reset_original_time_adjust(pool: *anyopaque) void;
extern fn zfish_threadpool_main_manager_clear_timeman(pool: *anyopaque) void;
extern fn zfish_threadpool_reset_for_reconfigure(pool: *anyopaque) void;
extern fn zfish_threadpool_bound_nodes_assign(
    pool: *anyopaque,
    nodes: ?[*]const usize,
    count: usize,
) void;
extern fn zfish_thread_nodes_searched(thread: *const anyopaque) u64;
extern fn zfish_thread_tb_hits(thread: *const anyopaque) u64;
extern fn zfish_thread_fill_summary(thread: *const anyopaque, out: *ThreadSummary) void;
const ThreadCallback = *const fn (?*anyopaque) callconv(.c) void;

extern fn zfish_thread_run_callback(
    thread: *anyopaque,
    callback: ThreadCallback,
    context: ?*anyopaque,
) void;
extern fn zfish_thread_worker_set_limits(thread: *anyopaque, limits: *const anyopaque) void;
// Stage 5: native LimitsType POD-tail copy (default build); see main.zig.
extern fn zfish_worker_set_limits(thread: *anyopaque, limits: *const anyopaque) void;
extern fn zfish_thread_worker_reset_root_setup_state(thread: *anyopaque) void;
extern fn zfish_thread_worker_set_root_moves(thread: *anyopaque, root_moves: *const anyopaque) void;
// Stage 5: native vector<RootMove> copy-assign (default build); see main.zig.
extern fn zfish_worker_set_root_moves(thread: *anyopaque, root_moves: *const anyopaque) void;
extern fn zfish_thread_worker_set_root_position(
    thread: *anyopaque,
    fen_ptr: [*]const u8,
    fen_len: usize,
    chess960: u8,
) void;
extern fn zfish_thread_worker_set_root_state(thread: *anyopaque, setup_state: *const anyopaque) void;
extern fn zfish_thread_worker_set_tb_config(thread: *anyopaque, config: TbConfig) void;
extern fn zfish_thread_clear_worker(thread: *anyopaque) void;
extern fn zfish_thread_wait_for_search_finished(thread: *anyopaque) void;
extern fn zfish_thread_start_searching(thread: *anyopaque) void;
extern fn zfish_thread_ensure_network_replicated(thread: *anyopaque) void;
extern fn zfish_shared_state_threads_value(shared_state: *const anyopaque) usize;
extern fn zfish_shared_state_numa_policy_mode(shared_state: *const anyopaque) u8;
extern fn zfish_shared_state_clear_histories(shared_state: *const anyopaque) void;
extern fn zfish_shared_state_insert_history(
    shared_state: *const anyopaque,
    numa_config: *const anyopaque,
    numa_index: usize,
    size: usize,
    do_bind: u8,
) void;
const NumaNodeCallback = *const fn (?*anyopaque) callconv(.c) void;

extern fn zfish_numa_config_execute_on_numa_node(
    numa_config: *const anyopaque,
    numa_index: usize,
    callback: NumaNodeCallback,
    context: ?*anyopaque,
) void;
extern fn zfish_numa_config_suggests_binding_threads(
    numa_config: *const anyopaque,
    requested: usize,
) u8;
extern fn zfish_numa_config_distribute_threads_among_nodes(
    numa_config: *const anyopaque,
    requested: usize,
    out_nodes: [*]usize,
) usize;
extern fn zfish_numa_config_node_count(numa_config: *const anyopaque) usize;
extern fn zfish_threadpool_add_main_thread(
    pool: *anyopaque,
    numa_config: *const anyopaque,
    shared_state: *const anyopaque,
    update_context: *const anyopaque,
    thread_id: usize,
    idx_in_numa: usize,
    total_numa: usize,
    numa_id: usize,
    do_bind: u8,
) void;
extern fn zfish_threadpool_add_worker_thread(
    pool: *anyopaque,
    numa_config: *const anyopaque,
    shared_state: *const anyopaque,
    thread_id: usize,
    idx_in_numa: usize,
    total_numa: usize,
    numa_id: usize,
    do_bind: u8,
) void;

const CreateThreadContext = struct {
    pool: *anyopaque,
    numa_config: *const anyopaque,
    shared_state: *const anyopaque,
    update_context: *const anyopaque,
    thread_id: usize,
    idx_in_numa: usize,
    total_numa: usize,
    numa_id: usize,
    do_bind: bool,
};

fn createThreadOnCurrentNode(context_ptr: ?*anyopaque) callconv(.c) void {
    const context: *const CreateThreadContext = @ptrCast(@alignCast(context_ptr.?));

    const bind_flag: u8 = @intFromBool(context.do_bind);

    if (context.thread_id == 0) {
        zfish_threadpool_add_main_thread(
            context.pool,
            context.numa_config,
            context.shared_state,
            context.update_context,
            context.thread_id,
            context.idx_in_numa,
            context.total_numa,
            context.numa_id,
            bind_flag,
        );
        return;
    }

    zfish_threadpool_add_worker_thread(
        context.pool,
        context.numa_config,
        context.shared_state,
        context.thread_id,
        context.idx_in_numa,
        context.total_numa,
        context.numa_id,
        bind_flag,
    );
}

fn applyRootSetup(context_ptr: ?*anyopaque) callconv(.c) void {
    const context: *const RootSetupContext = @ptrCast(@alignCast(context_ptr.?));
    // Stage 5: native LimitsType POD-tail copy in the default build; legacy keeps
    // the C++ worker->set_limits as the pure reference.
    if (legacyBuild())
        zfish_thread_worker_set_limits(context.thread, context.input.limits)
    else
        zfish_worker_set_limits(context.thread, context.input.limits);
    zfish_thread_worker_reset_root_setup_state(context.thread);
    // Stage 5: native vector<RootMove> copy-assign in the default build; the legacy
    // oracle keeps the C++ worker->set_root_moves so it stays the pure reference.
    if (legacyBuild())
        zfish_thread_worker_set_root_moves(context.thread, context.input.root_moves)
    else
        zfish_worker_set_root_moves(context.thread, context.input.root_moves);
    zfish_thread_worker_set_root_position(
        context.thread,
        context.input.fen_ptr,
        context.input.fen_len,
        context.input.chess960,
    );
    zfish_thread_worker_set_root_state(context.thread, context.input.setup_state);
    zfish_thread_worker_set_tb_config(context.thread, context.input.tb_config);
}

fn waitMainThread(pool: *anyopaque) void {
    if (zfish_threadpool_thread_count(pool) == 0)
        return;

    threadWaitFinished(zfish_threadpool_thread_at(pool, 0));
}

fn buildRootFen(pos: *const anyopaque) ?[*:0]u8 {
    var pieces: [square_count]u8 = undefined;
    zfish_accumulator_position_snapshot(pos, &pieces);
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
    pos: *anyopaque,
    storage: *anyopaque,

    fn init(root_fen: []const u8, chess960: u8) ScratchPosition {
        const pos = zfish_position_create() orelse @panic("OOM");
        errdefer zfish_position_destroy(pos);

        const storage = zfish_engine_state_list_storage_create() orelse @panic("OOM");
        errdefer zfish_engine_state_list_storage_destroy(storage);

        var scratch = ScratchPosition{ .pos = pos, .storage = storage };
        scratch.reset(root_fen, chess960);
        return scratch;
    }

    fn deinit(self: *ScratchPosition) void {
        zfish_engine_state_list_storage_destroy(self.storage);
        zfish_position_destroy(self.pos);
    }

    fn reset(self: *ScratchPosition, root_fen: []const u8, chess960: u8) void {
        const root_state = zfish_engine_state_list_storage_reset(self.storage);
        if (zfish_position_set_state(self.pos, root_fen.ptr, root_fen.len, chess960, root_state)) |err| {
            defer c.free(@ptrCast(err));
            @panic("scratch position set failed");
        }
    }

    fn doMove(self: *ScratchPosition, raw_move: u16) void {
        const next_state = zfish_engine_state_list_storage_push(self.storage);
        zfish_position_do_move_state(self.pos, raw_move, next_state);
    }
};

fn countPieces(pos: *const anyopaque) usize {
    var pieces: [square_count]u8 = undefined;
    zfish_accumulator_position_snapshot(pos, &pieces);

    var count: usize = 0;
    for (pieces) |piece| {
        if (piece != 0)
            count += 1;
    }
    return count;
}

fn loadTbConfig(options: *const anyopaque, pos: *const anyopaque) TbConfig {
    const snapshot = loadPositionSnapshot(pos);
    var config = TbConfig{
        .cardinality = zfish_options_syzygy_probe_limit(options),
        .root_in_tb = 0,
        .use_rule50 = zfish_options_syzygy_50_move_rule(options),
        .probe_depth = zfish_options_syzygy_probe_depth(options),
    };

    const max_cardinality: c_int = @intCast(zfish_tbprobe_max_cardinality());
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

fn probePosition(pos: *const anyopaque) TablebaseProbe {
    const snapshot = loadPositionSnapshot(pos);
    const fen_ptr = buildRootFen(pos) orelse @panic("OOM");
    defer c.free(@ptrCast(fen_ptr));
    const fen_text = std.mem.span(fen_ptr);
    return zfish_tbprobe_probe_fen(fen_text.ptr, fen_text.len, snapshot.is_chess960);
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
            if (zfish_movegen_generate_legal(scratch.pos, legal_moves[0..].ptr) == 0)
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

fn loadPositionSnapshot(pos: *const anyopaque) PositionSnapshot {
    var snapshot = std.mem.zeroes(PositionSnapshot);
    zfish_position_fill_snapshot(pos, &snapshot);
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
    pos: *const anyopaque,
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

    const root_moves = zfish_root_moves_create_ranked(ranked_moves.ptr, ranked_moves.len);
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
    pool: *anyopaque,
    numa_config: *const anyopaque,
    shared_state: *const anyopaque,
    update_context: *const anyopaque,
) void {
    if (zfish_threadpool_thread_count(pool) > 0) {
        waitMainThread(pool);
        if (legacyBuild()) zfish_threadpool_reset_for_reconfigure(pool) else native_threadpool.zfish_native_threadpool_clear(pool);
    }

    const requested = zfish_shared_state_threads_value(shared_state);
    if (requested == 0) {
        return;
    }

    var do_bind = false;
    switch (zfish_shared_state_numa_policy_mode(shared_state)) {
        numa_policy_none => do_bind = false,
        numa_policy_auto => do_bind = zfish_numa_config_suggests_binding_threads(numa_config, requested) != 0,
        else => do_bind = true,
    }

    const allocator = std.heap.c_allocator;
    const bound_nodes = allocator.alloc(usize, requested) catch @panic("OOM");
    defer allocator.free(bound_nodes);

    if (do_bind) {
        _ = zfish_numa_config_distribute_threads_among_nodes(
            numa_config,
            requested,
            bound_nodes.ptr,
        );
        zfish_threadpool_bound_nodes_assign(pool, bound_nodes.ptr, requested);
    } else {
        zfish_threadpool_bound_nodes_assign(pool, null, 0);
    }

    const node_count = @max(zfish_numa_config_node_count(numa_config), @as(usize, 1));
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

    zfish_shared_state_clear_histories(shared_state);

    var node_index: usize = 0;
    while (node_index < node_count) : (node_index += 1) {
        const count = threads_per_node[node_index];
        if (count != 0) {
            zfish_shared_state_insert_history(
                shared_state,
                numa_config,
                node_index,
                nextPowerOfTwo(count),
                @intFromBool(do_bind),
            );
        }
    }

    if (legacyBuild()) {
        // Legacy oracle: the original C++ Thread ctor loop (createThreadOnCurrentNode
        // per requested thread, NUMA-dispatched when binding).
        const created_per_node = allocator.alloc(usize, node_count) catch @panic("OOM");
        defer allocator.free(created_per_node);
        @memset(created_per_node, 0);

        var thread_id: usize = 0;
        while (thread_id < requested) : (thread_id += 1) {
            const numa_id: usize = if (do_bind) bound_nodes[thread_id] else 0;
            const idx_in_numa = created_per_node[numa_id];
            created_per_node[numa_id] += 1;

            var create_context = CreateThreadContext{
                .pool = pool,
                .numa_config = numa_config,
                .shared_state = shared_state,
                .update_context = update_context,
                .thread_id = thread_id,
                .idx_in_numa = idx_in_numa,
                .total_numa = threads_per_node[numa_id],
                .numa_id = numa_id,
                .do_bind = do_bind,
            };

            if (do_bind) {
                zfish_numa_config_execute_on_numa_node(
                    numa_config,
                    numa_id,
                    createThreadOnCurrentNode,
                    &create_context,
                );
            } else {
                createThreadOnCurrentNode(&create_context);
            }
        }
    } else {
        // Stage-4 contents-swap: build native Threads (idle loop + Worker) into the
        // C++ pool's threads vector via the native ThreadPool, replacing the per-thread
        // C++ Thread ctor loop. Single-node host (do_bind == false): the C++ worker-
        // builder uses numaIndex 0, idxInNuma == idx, totalNuma == requested.
        native_threadpool.zfish_native_threadpool_set(
            pool,
            @constCast(shared_state),
            update_context,
            requested,
        );
    }

    clear(pool);
    waitMainThread(pool);

    // Harness H4: prove the freshly (re)configured pool matches the Zig model of
    // the ThreadPool/Thread graph -- stop/increaseDepth zeroed, threads vector
    // sized == requested, boundThreadToNumaNode sized as bound, each Thread's
    // Worker slot bound. This anchors the offsets the native stage-4 construction
    // must reproduce, verified here against the live C++ Thread objects. Read-only;
    // panics on drift.
    zfish_verify_thread_graph(pool, requested, if (do_bind) requested else 0);
}

extern fn zfish_verify_thread_graph(pool: *const anyopaque, requested: usize, bound: usize) void;

pub fn pickBestThread(summaries: [*]const ThreadSummary, count: usize) usize {
    var best_index: usize = 0;
    var min_score: c_int = value_none;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (summaries[index].score < min_score)
            min_score = summaries[index].score;
    }

    index = 0;
    while (index < count) : (index += 1) {
        const best = summaries[best_index];
        const current = summaries[index];
        const best_vote = voteForMove(summaries, count, best.pv0_raw, min_score);
        const current_vote = voteForMove(summaries, count, current.pv0_raw, min_score);
        const best_decisive = isDecisiveBest(best);
        const current_decisive = isDecisiveBest(current);
        const better_voting_value =
            threadVotingValue(current, min_score) * @as(c_int, current.pv_has_more_than_two) > threadVotingValue(best, min_score) * @as(c_int, best.pv_has_more_than_two);

        if (best_decisive) {
            if (current_decisive and absInt(current.score) > absInt(best.score)) {
                best_index = index;
            }
        } else if (current_decisive or
            (!isLoss(current.score) and
                (current_vote > best_vote or (current_vote == best_vote and better_voting_value))))
        {
            best_index = index;
        }
    }

    return best_index;
}

pub fn startThinking(
    pool: *anyopaque,
    options: *const anyopaque,
    pos: *anyopaque,
    limits: *const anyopaque,
    states_slot: *anyopaque,
) void {
    waitMainThread(pool);
    zfish_threadpool_main_manager_set_stop_on_ponderhit(pool, 0);
    zfish_threadpool_set_stop_flag(pool, 0);
    zfish_threadpool_main_manager_set_ponder(pool, zfish_limits_ponder_mode(limits));
    zfish_threadpool_set_increase_depth(pool, 1);

    if (zfish_engine_pending_states_available(states_slot) != 0) {
        if (zfish_engine_handoff_pending_states(pool, states_slot) == 0)
            @panic("failed to hand off pending setup states");
    } else {
        zfish_threadpool_setup_states_adopt_from_slot(pool, states_slot);
        if (zfish_threadpool_has_setup_states(pool) == 0)
            @panic("missing setup states");
    }

    const setup_state = zfish_threadpool_setup_state_back(pool) orelse
        @panic("missing setup state");

    var legal_move_buffer: [256]u16 = undefined;
    const legal_move_count = zfish_movegen_generate_legal(pos, legal_move_buffer[0..].ptr);
    const legal_moves = legal_move_buffer[0..legal_move_count];
    const none_raw = uci_move.noneRaw();

    var selected_moves = std.ArrayList(u16).empty;
    defer selected_moves.deinit(std.heap.c_allocator);

    const searchmove_count = zfish_limits_searchmove_count(limits);
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
    defer zfish_root_moves_destroy(root_moves);
    const tb_config = root_setup.tb_config;
    const thread_count = zfish_threadpool_thread_count(pool);
    const allocator = std.heap.c_allocator;
    const root_setup_contexts = allocator.alloc(RootSetupContext, thread_count) catch @panic("OOM");
    defer allocator.free(root_setup_contexts);

    index = 0;
    while (index < thread_count) : (index += 1) {
        const thread = zfish_threadpool_thread_at(pool, index);
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
        const thread = zfish_threadpool_thread_at(pool, index);
        threadWaitFinished(thread);
    }

    const main_thread = zfish_threadpool_thread_at(pool, 0);
    threadStartSearching(main_thread);
}

pub fn clear(pool: *anyopaque) void {
    const thread_count = zfish_threadpool_thread_count(pool);
    if (thread_count == 0) {
        return;
    }

    var index: usize = 0;
    while (index < thread_count) : (index += 1) {
        threadClearWorker(zfish_threadpool_thread_at(pool, index));
    }

    index = 0;
    while (index < thread_count) : (index += 1) {
        threadWaitFinished(zfish_threadpool_thread_at(pool, index));
    }

    zfish_threadpool_main_manager_reset_best_previous_average_score(pool);
    zfish_threadpool_main_manager_reset_previous_time_reduction(pool);
    zfish_threadpool_main_manager_reset_calls_count(pool);
    zfish_threadpool_main_manager_reset_best_previous_score(pool);
    zfish_threadpool_main_manager_reset_original_time_adjust(pool);
    zfish_threadpool_main_manager_clear_timeman(pool);
}

pub fn nodesSearched(pool: *anyopaque) u64 {
    const thread_count = zfish_threadpool_thread_count(pool);
    var total: u64 = 0;
    var index: usize = 0;
    while (index < thread_count) : (index += 1) {
        total += zfish_thread_nodes_searched(zfish_threadpool_thread_at(pool, index));
    }
    return total;
}

pub fn tbHits(pool: *anyopaque) u64 {
    const thread_count = zfish_threadpool_thread_count(pool);
    var total: u64 = 0;
    var index: usize = 0;
    while (index < thread_count) : (index += 1) {
        total += zfish_thread_tb_hits(zfish_threadpool_thread_at(pool, index));
    }
    return total;
}

pub fn bestThreadIndex(pool: *anyopaque) usize {
    const thread_count = zfish_threadpool_thread_count(pool);
    if (thread_count == 0) {
        return 0;
    }
    if (thread_count > max_thread_summaries) {
        @panic("thread summary buffer too small");
    }

    var summaries: [max_thread_summaries]ThreadSummary = undefined;
    var index: usize = 0;
    while (index < thread_count) : (index += 1) {
        zfish_thread_fill_summary(zfish_threadpool_thread_at(pool, index), &summaries[index]);
    }

    return pickBestThread(&summaries, thread_count);
}

pub fn startSearching(pool: *anyopaque) void {
    const thread_count = zfish_threadpool_thread_count(pool);
    var index: usize = 1;
    while (index < thread_count) : (index += 1) {
        threadStartSearching(zfish_threadpool_thread_at(pool, index));
    }
}

pub fn waitForSearchFinished(pool: *anyopaque) void {
    const thread_count = zfish_threadpool_thread_count(pool);
    var index: usize = 1;
    while (index < thread_count) : (index += 1) {
        threadWaitFinished(zfish_threadpool_thread_at(pool, index));
    }
}

pub fn ensureNetworkReplicated(pool: *anyopaque) void {
    // M-FINAL cutover: in the default build the NNUE weights are always resident in native storage
    // (no C++ Network numa replica), so Worker::ensure_network_replicated is a no-op. Wrapping the
    // per-thread loop in the comptime legacyBuild() branch makes Zig prune it (and the now legacy-only
    // zfish_thread_ensure_network_replicated bridge reference) from the default exe entirely.
    if (legacyBuild()) {
        const thread_count = zfish_threadpool_thread_count(pool);
        var index: usize = 0;
        while (index < thread_count) : (index += 1) {
            zfish_thread_ensure_network_replicated(zfish_threadpool_thread_at(pool, index));
        }
    }
}

fn voteForMove(
    summaries: [*]const ThreadSummary,
    count: usize,
    move_raw: u16,
    min_score: c_int,
) c_int {
    var vote: c_int = 0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (summaries[index].pv0_raw == move_raw)
            vote += threadVotingValue(summaries[index], min_score);
    }
    return vote;
}

fn threadVotingValue(summary: ThreadSummary, min_score: c_int) c_int {
    return (summary.score - min_score + 14) * summary.root_depth;
}

fn isWin(score: c_int) bool {
    return score >= value_tb_win_in_max_ply;
}

fn isLoss(score: c_int) bool {
    return score <= value_tb_loss_in_max_ply;
}

fn isDecisive(score: c_int) bool {
    return isWin(score) or isLoss(score);
}

fn isDecisiveBest(summary: ThreadSummary) bool {
    return summary.score != -value_infinite and isDecisive(summary.score) and summary.score_is_bound == 0;
}

fn absInt(value: c_int) c_int {
    return if (value < 0) -value else value;
}

fn containsMove(moves: []const u16, target: u16) bool {
    for (moves) |move_raw| {
        if (move_raw == target) {
            return true;
        }
    }

    return false;
}
