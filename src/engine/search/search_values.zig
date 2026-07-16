// Serve as the single source of truth for the search value model: the score sentinels, mate
// arithmetic, bound/depth enums, and the value predicates shared by both the
// main search (searchImpl) and quiescence (qsearchImpl). Mirror the
// canonical constants in support/search.zig; keep one authoritative copy
// here to let both search bodies alias them instead of re-declaring the magic
// numbers (the old `q_*` spelling was a misnomer — the main search uses them
// too). Stay pure, std-only; import by path so the build graph is unchanged.

const std = @import("std");

pub const value_draw: c_int = 0;
pub const value_none: c_int = 32002;
pub const value_inf: c_int = 32001;
pub const value_mate: c_int = 32000;
pub const max_ply: c_int = 246;
pub const value_mate_in_max: c_int = value_mate - max_ply; // 31754
pub const value_tb: c_int = value_mate_in_max - 1; // 31753
pub const value_tb_win: c_int = value_tb - max_ply; // 31507

pub const depth_qs: c_int = 0;
pub const depth_unsearched: c_int = -2;
pub const depth_none: c_int = -3;

pub const bound_none: u8 = 0;
pub const bound_upper: u8 = 1;
pub const bound_lower: u8 = 2;
pub const bound_exact: u8 = 3;

pub const mt_promotion: u16 = 1 << 14;

pub const piece_value = [16]c_int{ 0, 208, 781, 825, 1276, 2538, 0, 0, 0, 208, 781, 825, 1276, 2538, 0, 0 };

pub inline fn isValid(v: c_int) bool {
    return v != value_none;
}
pub inline fn isWin(v: c_int) bool {
    return v >= value_tb_win;
}
pub inline fn isLoss(v: c_int) bool {
    return v <= -value_tb_win;
}
pub inline fn isDecisive(v: c_int) bool {
    return isWin(v) or isLoss(v);
}
pub inline fn matedIn(ply: c_int) c_int {
    return -value_mate + ply;
}
pub inline fn mateIn(ply: c_int) c_int {
    return value_mate - ply;
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "value model matches the canonical sentinels" {
    try std.testing.expectEqual(@as(c_int, 31754), value_mate_in_max);
    try std.testing.expectEqual(@as(c_int, 31753), value_tb);
    try std.testing.expectEqual(@as(c_int, 31507), value_tb_win);
    try std.testing.expect(isValid(0) and !isValid(value_none));
    try std.testing.expect(isWin(value_tb_win) and !isWin(value_tb_win - 1));
    try std.testing.expect(isLoss(-value_tb_win) and isDecisive(-value_tb_win));
    try std.testing.expectEqual(@as(c_int, -value_mate), matedIn(0));
    try std.testing.expectEqual(value_mate, mateIn(0));
}
