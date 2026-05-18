const std = @import("std");

const piece_to_char = " PNBRQK";
const king: u8 = 6;

pub fn buildCode(piece_types_ptr: [*]const u8, piece_count: usize) ?[*:0]u8 {
    return buildCodeAlloc(piece_types_ptr[0..piece_count]) catch null;
}

pub fn dtzBeforeZeroing(wdl: c_int) c_int {
    return switch (wdl) {
        2 => 1,
        1 => 101,
        -1 => -101,
        -2 => -1,
        else => 0,
    };
}

fn buildCodeAlloc(piece_types: []const u8) ![*:0]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(std.heap.c_allocator);

    var king_count: usize = 0;
    for (piece_types) |piece_type| {
        if (piece_type == king) {
            king_count += 1;
            if (king_count == 2) {
                try builder.append(std.heap.c_allocator, 'v');
            }
        }

        try builder.append(std.heap.c_allocator, piece_to_char[@as(usize, piece_type)]);
    }

    const result = try std.heap.c_allocator.allocSentinel(u8, builder.items.len, 0);
    @memcpy(result[0..builder.items.len], builder.items);
    return result.ptr;
}
