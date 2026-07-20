const std = @import("std");

pub const NnueTraceInput = struct {
    side_to_move_white: u8,
    bucket_count: usize,
    correct_bucket: usize,
    // upstream format_cp_aligned_dot(v) (nnue_misc.cpp:45) takes the SIGN from the raw internal
    // value v and the MAGNITUDE from to_cp(v). The *_raw arrays drive the sign; the *_cp arrays
    // the magnitude. total_cp is to_cp(psqt_raw + positional_raw) -- cp-of-sum, since upstream
    // formats to_cp(t.psqt + t.positional), NOT the sum of the two already-rounded cp values.
    psqt_raw: [*]const i32,
    positional_raw: [*]const i32,
    psqt_cp: [*]const i32,
    positional_cp: [*]const i32,
    total_cp: [*]const i32,
};

pub fn formatTrace(input: NnueTraceInput) ?[*:0]u8 {
    return formatTraceAlloc(input) catch null;
}

fn formatTraceAlloc(input: NnueTraceInput) ![*:0]u8 {
    const allocator = std.heap.c_allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    try buffer.appendSlice(
        allocator,
        "NNUE network contributions (Normalized, ",
    );
    try buffer.appendSlice(
        allocator,
        if (input.side_to_move_white != 0) "White to move)\n" else "Black to move)\n",
    );
    try buffer.appendSlice(allocator, "+------------+------------+------------+------------+\n");
    try buffer.appendSlice(allocator, "|   Bucket   |  Material  | Positional |   Total    |\n");
    try buffer.appendSlice(allocator, "|            |   (PSQT)   |  (Layers)  |            |\n");
    try buffer.appendSlice(allocator, "+------------+------------+------------+------------+\n");

    var bucket: usize = 0;
    while (bucket < input.bucket_count) : (bucket += 1) {
        var bucket_buffer: [64]u8 = undefined;
        // Match `"|  " << bucket << "        " << " |  "` (nnue_misc.cpp:78-79) byte-for-
        // byte: upstream closes each cell with `"  " << " |  "`, i.e. THREE spaces before
        // the pipe, not two. Every column was one space narrow.
        const bucket_text = std.fmt.bufPrint(&bucket_buffer, "|  {d}         |  ", .{bucket}) catch unreachable;
        try buffer.appendSlice(allocator, bucket_text);
        try appendAlignedDot(&buffer, input.psqt_raw[bucket], input.psqt_cp[bucket]);
        try buffer.appendSlice(allocator, "   |  ");
        try appendAlignedDot(&buffer, input.positional_raw[bucket], input.positional_cp[bucket]);
        try buffer.appendSlice(allocator, "   |  ");
        try appendAlignedDot(&buffer, input.psqt_raw[bucket] + input.positional_raw[bucket], input.total_cp[bucket]);
        try buffer.appendSlice(allocator, "   |");
        if (bucket == input.correct_bucket) {
            try buffer.appendSlice(allocator, " <-- this bucket is used");
        }
        try buffer.append(allocator, '\n');
    }

    try buffer.appendSlice(allocator, "+------------+------------+------------+------------+\n");

    const result = try allocator.allocSentinel(u8, buffer.items.len, 0);
    @memcpy(result[0..buffer.items.len], buffer.items);
    return result.ptr;
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
    const psqt = [_]i32{22}; // +0.22
    const positional = [_]i32{-76}; // -0.76 ; total -54 -> -0.54
    const total = [_]i32{-54};
    const s = formatTrace(.{
        .side_to_move_white = 1,
        .bucket_count = 1,
        .correct_bucket = 0,
        .psqt_raw = &psqt,
        .positional_raw = &positional,
        .psqt_cp = &psqt,
        .positional_cp = &positional,
        .total_cp = &total,
    }).?;
    defer std.heap.c_allocator.free(std.mem.span(s));
    const out = std.mem.span(s);

    try std.testing.expect(std.mem.indexOf(u8, out, "White to move)") != null);
    // Pin the sign + width-6 float format (centipawns*0.01) byte-for-byte:
    try std.testing.expect(std.mem.indexOf(u8, out, "+  0.22") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-  0.76") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-  0.54") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<-- this bucket is used") != null);
}

test "formatTrace: black-to-move header" {
    const z = [_]i32{0};
    const s = formatTrace(.{
        .side_to_move_white = 0,
        .bucket_count = 1,
        .correct_bucket = 9, // no bucket marked
        .psqt_raw = &z,
        .positional_raw = &z,
        .psqt_cp = &z,
        .positional_cp = &z,
        .total_cp = &z,
    }).?;
    defer std.heap.c_allocator.free(std.mem.span(s));
    const out = std.mem.span(s);
    try std.testing.expect(std.mem.indexOf(u8, out, "Black to move)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  0.00") != null); // zero -> space sign
    try std.testing.expect(std.mem.indexOf(u8, out, "<-- this bucket is used") == null);
}
