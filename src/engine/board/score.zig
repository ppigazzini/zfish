pub const ScoreClass = struct {
    kind: c_int,
    plies: c_int,
    win: c_int,
};

pub fn classify(
    value: c_int,
    value_tb_win_in_max_ply: c_int,
    value_tb: c_int,
    value_mate: c_int,
) ScoreClass {
    if (!isDecisive(value, value_tb_win_in_max_ply)) {
        return .{ .kind = 0, .plies = 0, .win = 0 };
    }

    const abs_value = if (value < 0) -value else value;
    if (abs_value <= value_tb) {
        const distance = value_tb - abs_value;
        return .{
            .kind = 1,
            .plies = if (value > 0) distance else -distance,
            .win = if (value > 0) 1 else 0,
        };
    }

    const distance = value_mate - abs_value;
    return .{
        .kind = 2,
        .plies = if (value > 0) distance else -distance,
        .win = if (value > 0) 1 else 0,
    };
}

fn isDecisive(value: c_int, value_tb_win_in_max_ply: c_int) bool {
    return value >= value_tb_win_in_max_ply or value <= -value_tb_win_in_max_ply;
}

// --- tests --------------------------------------------------------------
// Classify scores in a pure leaf (non-decisive / tablebase / mate). The live
// thresholds (search_emit) are (31507, 31753, 32000).
const std = @import("std");

test "classify: non-decisive scores are kind 0" {
    const r = classify(150, 31507, 31753, 32000);
    try std.testing.expectEqual(@as(c_int, 0), r.kind);
    try std.testing.expectEqual(@as(c_int, 0), r.plies);
    try std.testing.expectEqual(@as(c_int, 0), r.win);
}

test "classify: tablebase-range scores are kind 1, distance-to-value_tb encoded" {
    const r = classify(31600, 31507, 31753, 32000); // 31507 <= |v| <= 31753
    try std.testing.expectEqual(@as(c_int, 1), r.kind);
    try std.testing.expectEqual(@as(c_int, 1), r.win);
    try std.testing.expectEqual(@as(c_int, 31753 - 31600), r.plies);
}

test "classify: mate scores are kind 2, sign-encoded plies" {
    const win = classify(31950, 31507, 31753, 32000); // |v| > value_tb -> mate
    try std.testing.expectEqual(@as(c_int, 2), win.kind);
    try std.testing.expectEqual(@as(c_int, 32000 - 31950), win.plies);
    try std.testing.expectEqual(@as(c_int, 1), win.win);

    const loss = classify(-31950, 31507, 31753, 32000);
    try std.testing.expectEqual(@as(c_int, 2), loss.kind);
    try std.testing.expectEqual(@as(c_int, -(32000 - 31950)), loss.plies);
    try std.testing.expectEqual(@as(c_int, 0), loss.win);
}
