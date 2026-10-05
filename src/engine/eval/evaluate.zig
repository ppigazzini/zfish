const std = @import("std");

/// scaleEvaluation's inputs: the net's value, the side to move's optimism, and the
/// position's material ingredients, from which the two material readings the blend takes
/// are derived here rather than at each caller.
pub const EvalInput = struct {
    nnue: i32,
    optimism: i32,
    pawn_count: [2]i32, // by colour
    non_pawn_material: [2]i32, // by colour
    side_to_move: u1,
    rule50_count: i32,
    value_tb_loss_in_max_ply: i32,
    value_tb_win_in_max_ply: i32,
};

// Upstream's PawnValue (types.h), the pawn weight of simple_eval's material balance.
const pawn_value: i32 = 208;

pub const EvalTraceInput = struct {
    inner_trace_ptr: [*]const u8,
    inner_trace_len: usize,
    nnue_internal_value: i32,
    nnue_white_cp: i32,
    final_white_cp: i32,
};

/// Piece values for the SPINE-ISOLATION stub eval, in the order pawn, knight, bishop, rook,
/// queen. Deliberately round numbers with no relation to either engine's real tables: the only
/// property that matters is that upstream's patched `Eval::evaluate` uses the SAME five, so both
/// engines score every position identically and therefore search the SAME TREE. A stub that
/// diverged by one centipawn would produce two different node counts, and the whole comparison
/// would be two different workloads -- which is exactly how an earlier attempt at this
/// experiment concluded "the spine, not the NNUE, is the gap" and was wrong.
pub const stub_piece_values = [5]i32{ 100, 300, 300, 500, 900 };

/// Score a position by material alone, from the side to move's perspective. Counts are indexed
/// pawn..queen. No optimism, no alignment blend, no 50-move damping and no TB clamp -- the
/// clamp would be a no-op here anyway (max material is far inside the TB bounds), and leaving
/// all four out of BOTH engines keeps the two stubs a line-for-line match.
pub fn stubMaterialValue(white: [5]i32, black: [5]i32, side_to_move_is_white: bool) i32 {
    var w: i32 = 0;
    var b: i32 = 0;
    for (stub_piece_values, 0..) |v, i| {
        w += v * white[i];
        b += v * black[i];
    }
    return if (side_to_move_is_white) w - b else b - w;
}

/// Return upstream simple_eval: the material balance from the side to move's view.
pub fn simpleEval(input: EvalInput) i32 {
    const us = input.side_to_move;
    const them = us ^ 1;
    return pawn_value * (input.pawn_count[us] - input.pawn_count[them]) +
        input.non_pawn_material[us] - input.non_pawn_material[them];
}

/// Apply the search-dependent scaling (optimism, material, rule50) to the raw NNUE value --
/// upstream's scale_evaluation, since f740707f replaced the net's psqt/positional
/// complexity with how far the net and simple_eval AGREE. Arithmetic is C++ `int` with
/// truncating division throughout, i64 only where upstream casts to it.
pub fn scaleEvaluation(input: EvalInput) i32 {
    const se = simpleEval(input);
    const nnue = input.nnue;

    // Normalize both to [-1024, 1024] to measure their correlation.
    const se_norm = @divTrunc(se * 1024, absInt(se) + 1024);
    const nnue_norm = @divTrunc(nnue * 1024, absInt(nnue) + 1024);
    // Agreement means a straightforward position, disagreement a complex compensation.
    const alignment = @divTrunc(se_norm * nnue_norm, 512);

    // When winning, favor easy positions, and vice versa.
    const base_eval = nnue + @divTrunc(nnue * alignment, 65536) +
        @divTrunc(input.optimism * alignment, 16384);

    // Scale the combined evaluation by total material.
    const material = 521 * (input.pawn_count[0] + input.pawn_count[1]) +
        input.non_pawn_material[0] + input.non_pawn_material[1];
    var v: i32 = @intCast(@divTrunc(@as(i64, base_eval) * (90649 + material), 90649));

    // Damp the evaluation down linearly when shuffling.
    v -= @divTrunc(v * input.rule50_count, 189);

    // Keep the evaluation out of the tablebase range.
    return std.math.clamp(v, input.value_tb_loss_in_max_ply + 1, input.value_tb_win_in_max_ply - 1);
}

pub fn formatTrace(input: EvalTraceInput) ?[]u8 {
    return formatTraceAlloc(input) catch null;
}

fn formatTraceAlloc(input: EvalTraceInput) ![]u8 {
    const allocator = std.heap.c_allocator;
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    try buffer.append(allocator, '\n');
    try buffer.appendSlice(allocator, input.inner_trace_ptr[0..input.inner_trace_len]);
    try buffer.append(allocator, '\n');

    try appendIntLine(
        &buffer,
        "NNUE evaluation          ",
        input.nnue_internal_value,
        " (side to move, internal units)\n",
    );
    try appendFloatLine(
        &buffer,
        "NNUE evaluation        ",
        @as(f64, @floatFromInt(input.nnue_white_cp)) * 0.01,
        " (white side)\n",
    );
    try appendFloatLine(
        &buffer,
        "Final evaluation      ",
        @as(f64, @floatFromInt(input.final_white_cp)) * 0.01,
        " (white side) [with scaled NNUE, ...]\n",
    );

    return buffer.toOwnedSlice(allocator);
}

fn appendIntLine(
    buffer: *std.ArrayList(u8),
    prefix: []const u8,
    value: i32,
    suffix: []const u8,
) !void {
    // Emit `showpos` + the value, UNPADDED. This is not C's `%+15d`: upstream is C++
    // iostreams, and its `<< std::setw(15)` (evaluate.cpp:87) is a ONE-SHOT manipulator
    // consumed by the very next insertion -- the "NNUE evaluation          " literal, which
    // is already 25 chars, so it pads nothing and resets the width to 0 before the value is
    // inserted. Padding the value to 15 (the old reading) inserted 12 extra spaces:
    //   upstream: `NNUE evaluation          +10`
    //   zfish:    `NNUE evaluation                      +10`
    // std.fmt has no force-sign flag, so emit the sign explicitly.
    var signed: [32]u8 = undefined;
    const body = std.mem.print(&signed, "{c}{d}", .{
        @as(u8, if (value < 0) '-' else '+'),
        @abs(value),
    }) catch unreachable;
    try buffer.appendSlice(std.heap.c_allocator, prefix);
    try buffer.appendSlice(std.heap.c_allocator, body);
    try buffer.appendSlice(std.heap.c_allocator, suffix);
}

fn appendFloatLine(
    buffer: *std.ArrayList(u8),
    prefix: []const u8,
    value: f64,
    suffix: []const u8,
) !void {
    // Forced sign + 2 decimals, UNPADDED -- see appendIntLine: upstream's one-shot
    // `std::setw(15)` is consumed by the preceding string literal, never by the value, so
    // `%+15.2f` was the wrong model. std.fmt is byte-identical to C `%.2f` here because
    // `value` is always centipawns*0.01 -- a value on the 2-decimal grid, so no third
    // decimal exists and C's round-half-to-even can never disagree with std.fmt's
    // round-half-away. Proven byte-exact for every cp in [-2_000_000, 2_000_000] (60x the
    // mate-bounded eval range). std.fmt has no force-sign flag, so emit the sign explicitly.
    var digits: [32]u8 = undefined;
    const body = std.mem.print(&digits, "{c}{d:.2}", .{
        @as(u8, if (value < 0) '-' else '+'),
        @abs(value),
    }) catch unreachable;
    try buffer.appendSlice(std.heap.c_allocator, prefix);
    try buffer.appendSlice(std.heap.c_allocator, body);
    try buffer.appendSlice(std.heap.c_allocator, suffix);
}

fn absInt(value: i32) i32 {
    return if (value < 0) -value else value;
}

// --- tests --------------------------------------------------------------
fn testInput(nnue: i32, optimism: i32, rule50_count: i32) EvalInput {
    // Start position material: 8 pawns and 6989 non-pawn material a side, white to move.
    return .{
        .nnue = nnue,
        .optimism = optimism,
        .pawn_count = .{ 8, 8 },
        .non_pawn_material = .{ 6989, 6989 },
        .side_to_move = 0,
        .rule50_count = rule50_count,
        .value_tb_loss_in_max_ply = -30000,
        .value_tb_win_in_max_ply = 30000,
    };
}

test "scaleEvaluation: zero stays zero; balanced material only scales by material" {
    try std.testing.expectEqual(@as(i32, 0), scaleEvaluation(testInput(0, 0, 0)));
    // simple_eval 0 -> alignment 0, so v = 100 * (90649 + 22314) / 90649 = 124.
    try std.testing.expectEqual(@as(i32, 124), scaleEvaluation(testInput(100, 50, 0)));
    // rule50 damping: 124 - 124 * 50 / 189 = 124 - 32 = 92.
    try std.testing.expectEqual(@as(i32, 92), scaleEvaluation(testInput(100, 50, 50)));
}

test "scaleEvaluation: alignment truncates toward zero like C++ int division" {
    var input = testInput(-300, -40, 0);
    input.pawn_count = .{ 8, 7 }; // white a pawn up, white to move: simple_eval = 208
    // se_norm = 208*1024/1232 = 172, nnue_norm = -300*1024/1324 = -232,
    // alignment = 172 * -232 / 512 = -77 (trunc, not -78),
    // base = -300 + (-300*-77)/65536 + (-40*-77)/16384 = -300 + 0 + 0 = -300,
    // v = -300 * (90649 + 521*15 + 13978) / 90649 = -300 * 112442 / 90649 = -372.
    try std.testing.expectEqual(@as(i32, -372), scaleEvaluation(input));
    input.side_to_move = 1; // the same board from black's view: simple_eval = -208
    try std.testing.expectEqual(@as(i32, -208), simpleEval(input));
}

test "scaleEvaluation: clamps to the tb bounds" {
    try std.testing.expectEqual(@as(i32, 30000 - 1), scaleEvaluation(testInput(100000, 0, 0)));
    try std.testing.expectEqual(@as(i32, -30000 + 1), scaleEvaluation(testInput(-100000, 0, 0)));
}
