// Serve as the single source of truth for the search value model: the score sentinels, mate
// arithmetic, bound/depth enums, and the value predicates shared by both the
// main search (searchImpl) and quiescence (qsearchImpl). Mirror the
// canonical constants in support/search.zig; keep one authoritative copy
// here to let both search bodies alias them instead of re-declaring the magic
// numbers (both the main search and qsearch use them, so the names carry no
// `q_` prefix). Stay pure, std-only; import by path so the build graph is unchanged.

const std = @import("std");

pub const value_draw: i32 = 0;
pub const value_none: i32 = 32002;
pub const value_inf: i32 = 32001;
pub const value_mate: i32 = 32000;
pub const max_ply: i32 = 246;
pub const value_mate_in_max: i32 = value_mate - max_ply; // 31754
pub const value_tb: i32 = value_mate_in_max - 1; // 31753
pub const value_tb_win: i32 = value_tb - max_ply; // 31507

pub const depth_qs: i32 = 0;
pub const depth_unsearched: i32 = -2;
pub const depth_none: i32 = -3;

pub const bound_none: u8 = 0;
pub const bound_upper: u8 = 1;
pub const bound_lower: u8 = 2;
pub const bound_exact: u8 = 3;

pub const mt_promotion: u16 = 1 << 14;

pub const piece_value = [16]i32{ 0, 208, 781, 825, 1276, 2538, 0, 0, 0, 208, 781, 825, 1276, 2538, 0, 0 };

// Gate the verbose info output on the search being long enough to be worth narrating
// (upstream's `nodes > 10000000` in both search() and Search::Worker::iterative_deepening).
// Three call sites read it -- two in the ID loop, one in the root node body -- and they
// used to read two unrelated declarations: this one, and a bare literal in
// search_back.zig. Nothing related them, and no gate here could: the constant decides
// which INFO LINES are printed, never which nodes are searched, so the bench signature
// is blind to a sync that moves one and not the other.
pub const id_nodes_limit_output: u64 = 10_000_000;

pub inline fn isValid(v: i32) bool {
    return v != value_none;
}
pub inline fn isWin(v: i32) bool {
    return v >= value_tb_win;
}
pub inline fn isLoss(v: i32) bool {
    return v <= -value_tb_win;
}
pub inline fn isDecisive(v: i32) bool {
    return isWin(v) or isLoss(v);
}
pub inline fn matedIn(ply: i32) i32 {
    return -value_mate + ply;
}
pub inline fn mateIn(ply: i32) i32 {
    return value_mate - ply;
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "value model matches the canonical sentinels" {
    try std.testing.expectEqual(@as(i32, 31754), value_mate_in_max);
    try std.testing.expectEqual(@as(i32, 31753), value_tb);
    try std.testing.expectEqual(@as(i32, 31507), value_tb_win);
    try std.testing.expect(isValid(0) and !isValid(value_none));
    try std.testing.expect(isWin(value_tb_win) and !isWin(value_tb_win - 1));
    try std.testing.expect(isLoss(-value_tb_win) and isDecisive(-value_tb_win));
    try std.testing.expectEqual(@as(i32, -value_mate), matedIn(0));
    try std.testing.expectEqual(value_mate, mateIn(0));
}
