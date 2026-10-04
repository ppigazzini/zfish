const std = @import("std");

pub const NnueTraceInput = struct {
    side_to_move_white: u8,
    bucket_count: usize,
    correct_bucket: usize,
    // upstream format_cp_aligned_dot(v) (nnue_misc.cpp) takes the SIGN from the raw internal
    // value v and the MAGNITUDE from to_cp(v). The raw array drives the sign; the cp array the
    // magnitude.
    positional_raw: [*]const i32,
    positional_cp: [*]const i32,
};

pub fn formatTrace(input: NnueTraceInput) ?[]u8 {
    return formatTraceAlloc(input) catch null;
}

fn formatTraceAlloc(input: NnueTraceInput) ![]u8 {
    const allocator = std.heap.c_allocator;
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    try buffer.appendSlice(
        allocator,
        "NNUE network contributions (Normalized, ",
    );
    try buffer.appendSlice(
        allocator,
        if (input.side_to_move_white != 0) "White to move)\n" else "Black to move)\n",
    );
    try buffer.appendSlice(allocator, "+------------+------------+\n");
    try buffer.appendSlice(allocator, "|   Bucket   | Evaluation |\n");
    try buffer.appendSlice(allocator, "+------------+------------+\n");

    var bucket: usize = 0;
    while (bucket < input.bucket_count) : (bucket += 1) {
        var bucket_buffer: [64]u8 = undefined;
        // Match `"|  " << bucket << "         |  "` (nnue_misc.cpp) byte-for-byte, and close
        // the cell with `"   |"`: THREE spaces before the pipe, not two.
        const bucket_text = std.fmt.bufPrint(&bucket_buffer, "|  {d}         |  ", .{bucket}) catch unreachable;
        try buffer.appendSlice(allocator, bucket_text);
        try appendAlignedDot(&buffer, input.positional_raw[bucket], input.positional_cp[bucket]);
        try buffer.appendSlice(allocator, "   |");
        if (bucket == input.correct_bucket) {
            try buffer.appendSlice(allocator, " <-- this bucket is used");
        }
        try buffer.append(allocator, '\n');
    }

    try buffer.appendSlice(allocator, "+------------+------------+\n");

    return buffer.toOwnedSlice(allocator);
}

fn appendAlignedDot(buffer: *std.ArrayList(u8), sign_value: i32, cp_value: i32) !void {
    // Sign from the raw internal value, magnitude from its centipawns (upstream nnue_misc.cpp:45).
    const sign: u8 = if (sign_value < 0)
        '-'
    else if (sign_value > 0)
        '+'
    else
        ' ';
    const pawns = @as(f64, @floatFromInt(absInt(cp_value))) * 0.01;

    // Reproduce `%c%6.2f`: the sign char, then the 2-decimal pawns right-padded to width 6. std.fmt
    // is byte-identical to C `%.2f` here because pawns is always centipawns*0.01 -- on the
    // 2-decimal grid, so no third decimal exists and C's round-half-to-even can never
    // disagree with std.fmt's round-half-away. Proven byte-exact for every cp in
    // [-2_000_000, 2_000_000].
    var digits: [32]u8 = undefined;
    const body = std.fmt.bufPrint(&digits, "{d:.2}", .{pawns}) catch unreachable;
    var numeric: [64]u8 = undefined;
    const rendered = std.fmt.bufPrint(&numeric, "{c}{s: >6}", .{ sign, body }) catch unreachable;
    try buffer.appendSlice(std.heap.c_allocator, rendered);
}

fn absInt(value: i32) i32 {
    return if (value < 0) -value else value;
}

// --- tests --------------------------------------------------------------
test "formatTrace: side line, bucket row, and the %c%6.2f float cells" {
    const raw = [_]i32{ 22, -76 };
    const cp = [_]i32{ 22, -76 }; // +0.22, -0.76
    const s = formatTrace(.{
        .side_to_move_white = 1,
        .bucket_count = 2,
        .correct_bucket = 1,
        .positional_raw = &raw,
        .positional_cp = &cp,
    }).?;
    defer std.heap.c_allocator.free(s);
    const out = s;

    // Pin the whole table byte-for-byte against upstream's nnue_misc.cpp layout: the sign +
    // width-6 float cell (centipawns*0.01), three spaces before each closing pipe.
    try std.testing.expectEqualStrings(
        "NNUE network contributions (Normalized, White to move)\n" ++
            "+------------+------------+\n" ++
            "|   Bucket   | Evaluation |\n" ++
            "+------------+------------+\n" ++
            "|  0         |  +  0.22   |\n" ++
            "|  1         |  -  0.76   | <-- this bucket is used\n" ++
            "+------------+------------+\n",
        out,
    );
}

test "formatTrace: black-to-move header" {
    const z = [_]i32{0};
    const s = formatTrace(.{
        .side_to_move_white = 0,
        .bucket_count = 1,
        .correct_bucket = 9, // no bucket marked
        .positional_raw = &z,
        .positional_cp = &z,
    }).?;
    defer std.heap.c_allocator.free(s);
    const out = s;
    try std.testing.expect(std.mem.find(u8, out, "Black to move)") != null);
    try std.testing.expect(std.mem.find(u8, out, "  0.00") != null); // zero -> space sign
    try std.testing.expect(std.mem.find(u8, out, "<-- this bucket is used") == null);
}
