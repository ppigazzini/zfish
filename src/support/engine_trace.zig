// Engine eval-trace / visualize / snapshot cluster (M17.4a).
//
// The read-only inspection commands split out of engine.zig: the `eval` trace
// (traceEvalEngine/evalTrace/buildNnueTrace), the `d` board visualize
// (visualize/visualizeEngine), the FEN reader (fen/fenEngine), the NNUE
// accumulator scratch buffers those use, and the position-snapshot helpers
// (positionSummary/positionFen/probeTablebases/loadPositionSnapshot/countPieces/
// emptyTablebaseProbe). Grep-verified to have zero engine-core coupling: it calls
// only the engine-handle adapter (ne, duplicated), verifyNetwork (the engine_nnue
// leaf), its own siblings, and the downstream graph leaves. So it is a leaf; no
// import of engine, no cycle. engine.zig re-exports the external entry points
// (traceEvalEngine/visualizeEngine/fenEngine/accumulatorCachesCreate + the pub
// trace types) and aliases `fen` for its perft/flip callers.

const std = @import("std");
const c = @import("libc");
const position_snapshot = @import("position_snapshot");
const position_port = @import("position");
const uci_move = @import("uci_move");
const nnue_acc = @import("nnue_accumulator");
const evaluate_mod = @import("evaluate");
const graph_layout = @import("graph_layout");
const tablebase = @import("tablebase");
const option_port = @import("option");
const state_list = @import("state_list");
const nnue_misc_mod = @import("nnue_misc");
const uci_wdl = @import("uci_wdl");
const network_port = @import("network");
const native_engine = @import("native_engine");
const engine_util = @import("engine_util");
const engine_nnue = @import("engine_nnue");

const allocMessage = engine_util.allocMessage;
const appendFormat = engine_util.appendFormat;
const appendHexKey = engine_util.appendHexKey;
const appendPaddedInt = engine_util.appendPaddedInt;
const appendCheckers = engine_util.appendCheckers;
const verifyNetwork = engine_nnue.verifyNetwork;

const layer_stacks: usize = 8;
const square_count: usize = 64;
const piece_to_char = " PNBRQK  pnbrqk";
const white: u8 = 0;
const black: u8 = 1;
const white_oo: u8 = 1;
const white_ooo: u8 = 2;
const black_oo: u8 = 4;
const black_ooo: u8 = 8;
const sq_none: u8 = 64;
const max_ply: c_int = 246;
const value_mate: c_int = 32000;
const value_tb: c_int = value_mate - max_ply - 1;
const value_tb_win_in_max_ply: c_int = value_tb - max_ply;
const value_tb_loss_in_max_ply: c_int = -value_tb_win_in_max_ply;

const PositionSnapshot = position_snapshot.PositionSnapshot;

pub const PositionSummary = struct {
    side_to_move_white: u8,
    checkers: u64,
    key: u64,
    material: c_int,
    rule50_count: c_int,
};

pub const TablebaseProbe = tablebase.ProbeResult;

pub const EvalInput = struct {
    psqt: c_int,
    positional: c_int,
    optimism: c_int,
    material: c_int,
    rule50_count: c_int,
    value_tb_loss_in_max_ply: c_int,
    value_tb_win_in_max_ply: c_int,
};

pub const EvalOutput = struct {
    psqt: c_int,
    positional: c_int,
};

pub const TraceOutput = struct {
    psqt: [layer_stacks]c_int,
    positional: [layer_stacks]c_int,
    correct_bucket: usize,
};

pub const EvalTraceInput = struct {
    inner_trace_ptr: [*]const u8,
    inner_trace_len: usize,
    nnue_internal_value: c_int,
    nnue_white_cp: c_int,
    final_white_cp: c_int,
};

pub const NnueTraceInput = struct {
    side_to_move_white: u8,
    bucket_count: usize,
    correct_bucket: usize,
    psqt_cp: [*]const c_int,
    positional_cp: [*]const c_int,
};

// ======================================================================== //
// Trace / visualize / snapshot functions, moved verbatim from engine.zig.    //
// ======================================================================== //
fn accumulatorStackCreate() ?*anyopaque {
    const buf = std.c.malloc(graph_layout.accumulator_stack_size) orelse return null;
    @memset(@as([*]u8, @ptrCast(buf))[0..graph_layout.accumulator_stack_size], 0);
    nnue_acc.stackReset(buf);
    return buf;
}
fn accumulatorStackDestroy(stack: ?*anyopaque) void {
    if (stack) |buf| std.c.free(buf);
}
// `new AccumulatorCaches(network)` / delete, ported native: the C++ ctor clears every cache
// entry from the network FT biases; clearRefreshCache does exactly that over the caches block
// from the native FT biases (the loaded net). Relocated from main.zig (M16.7).
pub fn accumulatorCachesCreate() ?*anyopaque {
    const buf = std.c.malloc(graph_layout.accumulator_caches_size) orelse return null;
    const biases: [*]const i16 = @ptrCast(@alignCast(network_port.nativeFtPtr() orelse {
        std.c.free(buf);
        return null;
    }));
    nnue_acc.clearRefreshCache(@ptrCast(buf), biases);
    return buf;
}
fn accumulatorCachesDestroy(caches: ?*anyopaque) void {
    if (caches) |buf| std.c.free(buf);
}

pub fn traceEvalEngine(engine_ptr: *native_engine.NativeEngine) ?[*:0]u8 {
    verifyNetwork();

    const source_pos = engine_ptr.positionPtr();
    const fen_ptr = fen(source_pos) orelse return null;
    defer c.free(@ptrCast(fen_ptr));
    const fen_text = std.mem.span(fen_ptr);

    const trace_pos = position_port.create() orelse return null;
    defer position_port.destroy(trace_pos);

    const state_storage = state_list.storageCreate() orelse return null;
    defer state_list.storageDestroy(state_storage);
    const state = state_list.storageReset(state_storage);

    if (position_port.setPositionState(trace_pos, fen_text.ptr, fen_text.len, @intFromBool(option_port.uciChess960()), state)) |err| {
        defer c.free(@ptrCast(err));
        return null;
    }

    return evalTrace(trace_pos);
}

pub fn evalTrace(pos: *const position_port.Position) ?[*:0]u8 {
    const summary = positionSummary(pos);
    if (summary.checkers != 0)
        return allocMessage("Final evaluation: none (in check)", .{});

    const caches = accumulatorCachesCreate() orelse return null;
    defer accumulatorCachesDestroy(caches);

    const inner_trace_ptr = buildNnueTrace(pos, summary, caches) orelse return null;
    defer c.free(@ptrCast(inner_trace_ptr));
    const inner_trace = std.mem.span(inner_trace_ptr);

    const accumulators = accumulatorStackCreate() orelse return null;
    defer accumulatorStackDestroy(accumulators);

    const nnue_output = network_port.evaluate(pos, accumulators, caches);
    const nnue_value = nnue_output.psqt + nnue_output.positional;
    const nnue_white_side = if (summary.side_to_move_white != 0) nnue_value else -nnue_value;

    const final_value = evaluate_mod.computeValue(.{
        .psqt = nnue_output.psqt,
        .positional = nnue_output.positional,
        .optimism = 0,
        .material = summary.material,
        .rule50_count = summary.rule50_count,
        .value_tb_loss_in_max_ply = value_tb_loss_in_max_ply,
        .value_tb_win_in_max_ply = value_tb_win_in_max_ply,
    });
    const final_white_side = if (summary.side_to_move_white != 0) final_value else -final_value;

    return evaluate_mod.formatTrace(.{
        .inner_trace_ptr = inner_trace.ptr,
        .inner_trace_len = inner_trace.len,
        .nnue_internal_value = nnue_value,
        .nnue_white_cp = uci_wdl.toCp(nnue_white_side, summary.material),
        .final_white_cp = uci_wdl.toCp(final_white_side, summary.material),
    });
}

pub fn fen(pos: *const position_port.Position) ?[*:0]u8 {
    return positionFen(pos, null);
}

pub fn fenEngine(engine_ptr: *native_engine.NativeEngine) ?[*:0]u8 {
    return fen(engine_ptr.positionPtr());
}

pub fn visualize(pos: *const position_port.Position) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    var pieces: [square_count]u8 = [_]u8{0} ** square_count;
    position_port.accumulatorSnapshot(pos, &pieces);

    const summary = positionSummary(pos);
    const fen_ptr = positionFen(pos, &pieces) orelse return null;
    defer c.free(@ptrCast(fen_ptr));
    const fen_text = std.mem.span(fen_ptr);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    buffer.appendSlice(allocator, "\n +---+---+---+---+---+---+---+---+\n") catch return null;

    var rank: usize = 8;
    while (rank > 0) {
        rank -= 1;

        var file: usize = 0;
        while (file < 8) : (file += 1) {
            const square_index = rank * 8 + file;
            buffer.appendSlice(allocator, " | ") catch return null;
            buffer.append(allocator, piece_to_char[pieces[square_index]]) catch return null;
        }

        appendFormat(
            &buffer,
            " | {d}\n +---+---+---+---+---+---+---+---+\n",
            .{rank + 1},
        ) catch return null;
    }

    buffer.appendSlice(allocator, "   a   b   c   d   e   f   g   h\n\nFen: ") catch return null;
    buffer.appendSlice(allocator, fen_text) catch return null;
    buffer.appendSlice(allocator, "\nKey: ") catch return null;
    appendHexKey(&buffer, summary.key) catch return null;
    buffer.appendSlice(allocator, "\nCheckers: ") catch return null;
    appendCheckers(&buffer, summary.checkers) catch return null;

    const tb = probeTablebases(pos, &pieces);
    if (tb.available != 0) {
        buffer.appendSlice(allocator, "\nTablebases WDL: ") catch return null;
        appendPaddedInt(&buffer, tb.wdl) catch return null;
        appendFormat(&buffer, " ({d})\nTablebases DTZ: ", .{tb.wdl_state}) catch return null;
        appendPaddedInt(&buffer, tb.dtz) catch return null;
        appendFormat(&buffer, " ({d})", .{tb.dtz_state}) catch return null;
    }

    const owned = allocator.allocSentinel(u8, buffer.items.len, 0) catch return null;
    @memcpy(owned[0..buffer.items.len], buffer.items);
    return owned.ptr;
}

pub fn visualizeEngine(engine_ptr: *native_engine.NativeEngine) ?[*:0]u8 {
    return visualize(engine_ptr.positionPtr());
}

fn buildNnueTrace(
    pos: *const position_port.Position,
    summary: PositionSummary,
    caches: *anyopaque,
) ?[*:0]u8 {
    const accumulators = accumulatorStackCreate() orelse return null;
    defer accumulatorStackDestroy(accumulators);
    nnue_acc.stackReset(accumulators);

    const trace = network_port.traceEvaluate(pos, accumulators, caches);
    var psqt_cp: [layer_stacks]c_int = undefined;
    var positional_cp: [layer_stacks]c_int = undefined;

    var bucket: usize = 0;
    while (bucket < layer_stacks) : (bucket += 1) {
        psqt_cp[bucket] = uci_wdl.toCp(trace.psqt[bucket], summary.material);
        positional_cp[bucket] = uci_wdl.toCp(trace.positional[bucket], summary.material);
    }

    return nnue_misc_mod.formatTrace(.{
        .side_to_move_white = summary.side_to_move_white,
        .bucket_count = layer_stacks,
        .correct_bucket = trace.correct_bucket,
        .psqt_cp = &psqt_cp,
        .positional_cp = &positional_cp,
    });
}

fn positionSummary(pos: *const position_port.Position) PositionSummary {
    const snapshot = loadPositionSnapshot(pos);
    return .{
        .side_to_move_white = if (snapshot.side_to_move == white) 1 else 0,
        .checkers = snapshot.checkers,
        .key = snapshot.key,
        .material = snapshot.material_value,
        .rule50_count = snapshot.rule50_count,
    };
}

fn positionFen(pos: *const position_port.Position, pieces_opt: ?*const [square_count]u8) ?[*:0]u8 {
    const snapshot = loadPositionSnapshot(pos);
    var pieces_storage: [square_count]u8 = undefined;
    const pieces: *const [square_count]u8 = if (pieces_opt) |provided|
        provided
    else blk: {
        position_port.accumulatorSnapshot(pos, &pieces_storage);
        break :blk &pieces_storage;
    };

    return position_port.formatFen(
        @ptrCast(pieces),
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

fn probeTablebases(pos: *const position_port.Position, pieces_opt: ?*const [square_count]u8) TablebaseProbe {
    const snapshot = loadPositionSnapshot(pos);
    if (snapshot.castling_rights != 0) {
        return emptyTablebaseProbe();
    }

    var pieces_storage: [square_count]u8 = undefined;
    const pieces: *const [square_count]u8 = if (pieces_opt) |provided|
        provided
    else blk: {
        position_port.accumulatorSnapshot(pos, &pieces_storage);
        break :blk &pieces_storage;
    };

    if (countPieces(pieces) > tablebase.maxCardinality()) {
        return emptyTablebaseProbe();
    }

    const fen_ptr = positionFen(pos, pieces) orelse return emptyTablebaseProbe();
    defer c.free(@ptrCast(fen_ptr));
    const fen_text = std.mem.span(fen_ptr);
    return tablebase.probeFen(fen_text.ptr, fen_text.len, snapshot.is_chess960);
}

fn loadPositionSnapshot(pos: *const position_port.Position) PositionSnapshot {
    var snapshot = std.mem.zeroes(PositionSnapshot);
    position_port.fillSnapshot(pos, &snapshot);
    return snapshot;
}

fn countPieces(pieces: *const [square_count]u8) usize {
    var count: usize = 0;
    for (pieces.*) |piece| {
        if (piece != 0) {
            count += 1;
        }
    }
    return count;
}

fn emptyTablebaseProbe() TablebaseProbe {
    return .{
        .available = 0,
        .wdl = 0,
        .wdl_state = 0,
        .dtz = 0,
        .dtz_state = 0,
    };
}
