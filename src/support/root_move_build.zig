// Root-move construction + Syzygy tablebase root-ranking (extracted from thread.zig, M21).
//
// The `go`-path root-move builder: ranks the legal / searchmoves by DTZ then WDL when
// tablebases are loaded, builds the native RootMoves array the workers bind to, and owns
// the scratch position + root-FEN helpers it needs. Pure over position / state_list /
// tablebase / movegen / option -- NO thread or worker-pool dependency (thread.zig imports
// this leaf, never the reverse), so the OOM paths here are unit-testable in isolation.

const std = @import("std");
const position_port = @import("position");
const state_list = @import("state_list");
const tablebase = @import("tablebase");
const option_port = @import("option");
const movegen_port = @import("movegen");
const position_snapshot = @import("position_snapshot");

const PositionSnapshot = position_snapshot.PositionSnapshot;
const PendingStateStorage = state_list.PendingStateStorage;

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

// Native Search::RootMoves (= the C++ std::vector<RootMove>) builder/destroyer, relocated
// from main.zig (M16.7). Lays out a 24-byte {begin,end,cap} header over a `count`-element
// RootMove array (stride graph_layout.root_move_size == 552), each element zeroed then
// initialised to the RootMove default (scores at -VALUE_INFINITE) with the ranked tb fields
// and the single-move PV. Matches the vector the worker binds by reference.
// M19.1 (the transient src header, retired now that M20 confirmed these are just
// containers): the ranked source RootMoves is a plain []RootMove -- no hand-built
// 24-byte {begin,end,cap} header. The worker still copies it into its own vector-header
// buffer (workerSetRootMoves reads src.ptr/src.len). @sizeOf(RootMove)==552.
fn rootMovesCreateRanked(items: [*]const RankedRootMove, count: usize) ?[]position_port.RootMove {
    if (count == 0) return &[_]position_port.RootMove{};
    const elems = std.heap.c_allocator.alloc(position_port.RootMove, count) catch return null;
    for (elems, 0..) |*rm, i| {
        rm.* = std.mem.zeroes(position_port.RootMove);
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
    return elems;
}
pub fn rootMovesDestroy(rm: []position_port.RootMove) void {
    if (rm.len != 0) std.heap.c_allocator.free(rm);
}

pub fn buildRootFen(pos: *const position_port.Position) ?[*:0]u8 {
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
    storage: *PendingStateStorage,

    fn init(root_fen: []const u8, chess960: u8) !ScratchPosition {
        const pos = position_port.create() orelse return error.OutOfMemory;
        errdefer position_port.destroy(pos);

        const storage = state_list.storageCreate() orelse return error.OutOfMemory;
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
            defer std.heap.c_allocator.free(std.mem.span(err));
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

fn loadTbConfig(pos: *const position_port.Position) TbConfig {
    // syzygy options read from the native global option model (option_port.*), not a
    // handle -- so no `options` param is threaded here (M18.5 vestigial-handle deletion).
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

fn probePosition(pos: *const position_port.Position) !TablebaseProbe {
    const snapshot = loadPositionSnapshot(pos);
    const fen_ptr = buildRootFen(pos) orelse return error.OutOfMemory;
    defer std.heap.c_allocator.free(std.mem.span(fen_ptr));
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
) !DtzRankResult {
    var scratch = try ScratchPosition.init(root_fen, chess960);
    defer scratch.deinit();

    const bound: c_int = if (rule50) @divTrunc(max_dtz, 2) - 100 else 1;

    for (ranked_moves) |*ranked_move| {
        scratch.reset(root_fen, chess960);
        scratch.doMove(ranked_move.raw_move);

        var dtz: c_int = 0;
        if (loadPositionSnapshot(scratch.pos).rule50_count == 0) {
            const probe = try probePosition(scratch.pos);
            if (probe.wdl_state == probe_fail)
                return .fallback_to_wdl;
            dtz = dtzBeforeZeroing(-probe.wdl);
        } else if ((rule50 and position_port.isDraw(scratch.pos, 1)) or
            position_port.isRepetition(scratch.pos, 1))
        {
            dtz = 0;
        } else {
            const probe = try probePosition(scratch.pos);
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

pub fn loadPositionSnapshot(pos: *const position_port.Position) PositionSnapshot {
    var snapshot = std.mem.zeroes(PositionSnapshot);
    position_port.fillSnapshot(pos, &snapshot);
    return snapshot;
}

fn rankRootMovesWdl(
    root_fen: []const u8,
    chess960: u8,
    rule50: bool,
    ranked_moves: []RankedRootMove,
) !bool {
    var scratch = try ScratchPosition.init(root_fen, chess960);
    defer scratch.deinit();

    for (ranked_moves) |*ranked_move| {
        scratch.reset(root_fen, chess960);
        scratch.doMove(ranked_move.raw_move);

        var wdl: c_int = undefined;
        if (position_port.isDraw(scratch.pos, 1)) {
            wdl = wdl_draw;
        } else {
            const probe = try probePosition(scratch.pos);
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

pub fn buildRootMoves(
    allocator: std.mem.Allocator,
    pos: *const position_port.Position,
    root_fen: []const u8,
    chess960: u8,
    move_raws: []const u16,
) !struct { root_moves: []position_port.RootMove, tb_config: TbConfig } {
    const ranked_moves = try allocator.alloc(RankedRootMove, move_raws.len);
    defer allocator.free(ranked_moves);

    for (move_raws, 0..) |raw_move, index| {
        ranked_moves[index] = .{
            .raw_move = raw_move,
            .reserved = 0,
            .tb_rank = 0,
            .tb_score = 0,
        };
    }

    var tb_config = loadTbConfig(pos);
    var dtz_available = true;

    if (tb_config.cardinality != 0) {
        const root_snapshot = loadPositionSnapshot(pos);
        const dtz_result = try rankRootMovesDtz(
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
                if (try rankRootMovesWdl(root_fen, chess960, tb_config.use_rule50 != 0, ranked_moves)) {
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
        return error.OutOfMemory;
    return .{
        .root_moves = root_moves,
        .tb_config = tb_config,
    };
}
