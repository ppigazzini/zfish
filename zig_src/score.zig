pub const ScoreClass = extern struct {
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
