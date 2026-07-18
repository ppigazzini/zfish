// Name the three outcomes the classifier distinguishes, so a consumer switches on them
// exhaustively instead of on 0/1/2 with an `else`.
pub const ScoreKind = enum { non_decisive, mate, tablebase };

pub const ScoreClass = struct {
    kind: ScoreKind,
    plies: i32,
    win: bool,
};

pub fn classify(
    value: i32,
    value_tb_win_in_max_ply: i32,
    value_tb: i32,
    value_mate: i32,
) ScoreClass {
    if (!isDecisive(value, value_tb_win_in_max_ply)) {
        return .{ .kind = .non_decisive, .plies = 0, .win = false };
    }

    const abs_value = if (value < 0) -value else value;
    if (abs_value <= value_tb) {
        const distance = value_tb - abs_value;
        return .{
            .kind = .tablebase,
            .plies = if (value > 0) distance else -distance,
            .win = value > 0,
        };
    }

    const distance = value_mate - abs_value;
    return .{
        .kind = .mate,
        .plies = if (value > 0) distance else -distance,
        .win = value > 0,
    };
}

fn isDecisive(value: i32, value_tb_win_in_max_ply: i32) bool {
    return value >= value_tb_win_in_max_ply or value <= -value_tb_win_in_max_ply;
}

// --- tests --------------------------------------------------------------
// Classify scores in a pure leaf (non-decisive / tablebase / mate). The live
// thresholds (search_emit) are (31507, 31753, 32000).
const std = @import("std");

test "classify: non-decisive scores are .non_decisive" {
    const r = classify(150, 31507, 31753, 32000);
    try std.testing.expectEqual(.non_decisive, r.kind);
    try std.testing.expectEqual(@as(i32, 0), r.plies);
    try std.testing.expectEqual(false, r.win);
}

test "classify: tablebase-range scores are .tablebase, distance-to-value_tb encoded" {
    const r = classify(31600, 31507, 31753, 32000); // 31507 <= |v| <= 31753
    try std.testing.expectEqual(.tablebase, r.kind);
    try std.testing.expectEqual(true, r.win);
    try std.testing.expectEqual(@as(i32, 31753 - 31600), r.plies);
}

test "classify: mate scores are .mate, sign-encoded plies" {
    const win = classify(31950, 31507, 31753, 32000); // |v| > value_tb -> mate
    try std.testing.expectEqual(.mate, win.kind);
    try std.testing.expectEqual(@as(i32, 32000 - 31950), win.plies);
    try std.testing.expectEqual(true, win.win);

    const loss = classify(-31950, 31507, 31753, 32000);
    try std.testing.expectEqual(.mate, loss.kind);
    try std.testing.expectEqual(@as(i32, -(32000 - 31950)), loss.plies);
    try std.testing.expectEqual(false, loss.win);
}
