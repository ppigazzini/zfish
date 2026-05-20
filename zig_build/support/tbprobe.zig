const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});

const piece_to_char = " PNBRQK";
const king: u8 = 6;

extern fn zfish_tbprobe_has_wdl_file(code_ptr: [*]const u8, code_len: usize) u8;
extern fn zfish_tbprobe_has_dtz_file(code_ptr: [*]const u8, code_len: usize) u8;
extern fn zfish_tbprobe_note_dtz_found(tables: *anyopaque) void;
extern fn zfish_tbprobe_register_wdl_table(
    tables: *anyopaque,
    code_ptr: [*]const u8,
    code_len: usize,
    piece_count: usize,
) void;

pub fn addTables(tables: *anyopaque, piece_types_ptr: [*]const u8, piece_count: usize) void {
    const code_ptr = buildCode(piece_types_ptr, piece_count) orelse return;
    defer c.free(@ptrCast(code_ptr));

    const code = std.mem.span(code_ptr);
    if (zfish_tbprobe_has_dtz_file(code.ptr, code.len) != 0)
        zfish_tbprobe_note_dtz_found(tables);

    if (zfish_tbprobe_has_wdl_file(code.ptr, code.len) == 0)
        return;

    zfish_tbprobe_register_wdl_table(tables, code.ptr, code.len, piece_count);
}

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
