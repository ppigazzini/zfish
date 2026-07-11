const std = @import("std");
const c = @import("libc");

pub const NnueTraceInput = struct {
    side_to_move_white: u8,
    bucket_count: usize,
    correct_bucket: usize,
    psqt_cp: [*]const c_int,
    positional_cp: [*]const c_int,
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
        // `%zu` has no width here, so `{d}` reproduces it byte-for-byte.
        const bucket_text = std.fmt.bufPrint(&bucket_buffer, "|  {d}        |  ", .{bucket}) catch unreachable;
        try buffer.appendSlice(allocator, bucket_text);
        try appendAlignedDot(&buffer, input.psqt_cp[bucket]);
        try buffer.appendSlice(allocator, "  |  ");
        try appendAlignedDot(&buffer, input.positional_cp[bucket]);
        try buffer.appendSlice(allocator, "  |  ");
        try appendAlignedDot(&buffer, input.psqt_cp[bucket] + input.positional_cp[bucket]);
        try buffer.appendSlice(allocator, "  |");
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

fn appendAlignedDot(buffer: *std.ArrayList(u8), cp_value: c_int) !void {
    const sign: u8 = if (cp_value < 0)
        '-'
    else if (cp_value > 0)
        '+'
    else
        ' ';
    const pawns = @as(f64, @floatFromInt(absInt(cp_value))) * 0.01;

    // Kept on C snprintf deliberately: C's `%.2f` rounds halves to even (0.125 -> "0.12")
    // whereas std.fmt rounds halves away (-> "0.13"). The eval trace must stay byte-exact
    // against the goldens, so the float formats stay on libc until we can match glibc's
    // round-half-to-even. Integer/hex formats (no such divergence) moved to std.fmt.
    var numeric: [64]u8 = undefined;
    const len = c.snprintf(&numeric, numeric.len, "%c%6.2f", sign, pawns);
    try buffer.appendSlice(std.heap.c_allocator, numeric[0..@intCast(len)]);
}

fn absInt(value: c_int) c_int {
    return if (value < 0) -value else value;
}
