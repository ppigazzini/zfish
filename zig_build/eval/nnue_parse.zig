// Native .nnue parse primitives.
//
// The C++ Network's last remaining job is parsing the .nnue file into its
// (already-permuted) weight memory; Zig currently copies those bytes out. To
// retire the C++ Network entirely, Zig must parse the file itself. These are the
// verified building blocks of that parse, matching src/nnue exactly:
//
//   * decodeLebI16 / decodeLebI32 -- signed LEB128 with the same sign-extension
//     and 32-bit shift masking as read_leb_128_detail (nnue_common.h).
//   * permuteBlocks -- the byte-block reorder of permute<> (nnue_feature_
//     transformer.h). For the SSE4.1 target PackusEpi16Order is the identity
//     {0..7}, so permute_weights is a no-op here; the routine is kept general
//     and exercised with a non-trivial order in tests.
//   * weightIndexScrambled -- get_weight_index_scrambled (affine_transform.h),
//     the SSSE3 weight index permutation the layer parse writes through and the
//     Zig propagate already reads back.

const std = @import("std");

// SSE4.1 PackusEpi16Order: identity. Kept explicit so the assumption is visible
// and a future wide-SIMD target can swap it.
pub const packus_epi16_order_sse41 = [8]usize{ 0, 1, 2, 3, 4, 5, 6, 7 };

// Signed LEB128 decode of `count` values from `src` into `out`, returning the
// number of source bytes consumed. Mirrors read_leb_128_detail: 7 bits per byte,
// shift masked to 32, sign-extend when the final shift < 32 and bit 0x40 is set.
pub fn decodeLeb(comptime IntType: type, src: []const u8, out: []IntType, count: usize) usize {
    std.debug.assert(out.len >= count);
    var pos: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var result: u32 = 0;
        var shift: u6 = 0;
        while (true) {
            const byte = src[pos];
            pos += 1;
            result |= @as(u32, byte & 0x7f) << @intCast(@as(u32, shift) % 32);
            shift +%= 7;
            if (byte & 0x80 == 0) {
                if (shift < 32 and (byte & 0x40) != 0) {
                    // sign-extend: result | ~((1 << shift) - 1)
                    const mask = ~((@as(u32, 1) << @intCast(shift)) - 1);
                    result |= mask;
                }
                const UnsignedT = std.meta.Int(.unsigned, @bitSizeOf(IntType));
                out[i] = @bitCast(@as(UnsignedT, @truncate(result)));
                break;
            }
        }
    }
    return pos;
}

// permute<BlockSize>: reorder `order.len` blocks of `block_size` bytes within
// each (block_size * order.len)-byte chunk of `data`.
pub fn permuteBlocks(data: []u8, block_size: usize, order: []const usize, scratch: []u8) void {
    const chunk = block_size * order.len;
    std.debug.assert(data.len % chunk == 0);
    std.debug.assert(scratch.len >= chunk);
    var i: usize = 0;
    while (i < data.len) : (i += chunk) {
        const values = data[i .. i + chunk];
        for (order, 0..) |src_block, j| {
            const dst = scratch[j * block_size .. j * block_size + block_size];
            const src = values[src_block * block_size .. src_block * block_size + block_size];
            @memcpy(dst, src);
        }
        @memcpy(values, scratch[0..chunk]);
    }
}

// get_weight_index_scrambled(i): the SSSE3 affine weight index permutation.
pub fn weightIndexScrambled(i: usize, padded_input: usize, output_dims: usize) usize {
    return (i / 4) % (padded_input / 4) * output_dims * 4 + i / padded_input * 4 + i % 4;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

// Reference signed-LEB128 encoder (standard) to round-trip against the decoder.
fn encodeOne(comptime IntType: type, v: IntType, buf: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    var value: i64 = v;
    while (true) {
        var byte: u8 = @intCast(value & 0x7f);
        value >>= 7;
        const sign_bit = byte & 0x40;
        if ((value == 0 and sign_bit == 0) or (value == -1 and sign_bit != 0)) {
            try buf.append(a, byte);
            break;
        }
        byte |= 0x80;
        try buf.append(a, byte);
    }
}

test "signed LEB128 decode round-trips i16 and i32" {
    const a = testing.allocator;
    const vals16 = [_]i16{ 0, 1, -1, 63, -64, 127, -128, 1000, -1000, 32767, -32768 };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    for (vals16) |v| try encodeOne(i16, v, &buf, a);

    var out: [vals16.len]i16 = undefined;
    const consumed = decodeLeb(i16, buf.items, &out, vals16.len);
    try testing.expectEqual(buf.items.len, consumed);
    try testing.expectEqualSlices(i16, &vals16, &out);

    const vals32 = [_]i32{ 0, 1, -1, 123456, -123456, 2147483647, -2147483648 };
    var buf2 = std.ArrayList(u8).empty;
    defer buf2.deinit(a);
    for (vals32) |v| try encodeOne(i32, v, &buf2, a);
    var out2: [vals32.len]i32 = undefined;
    _ = decodeLeb(i32, buf2.items, &out2, vals32.len);
    try testing.expectEqualSlices(i32, &vals32, &out2);
}

test "permuteBlocks identity leaves data unchanged" {
    var data: [128]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);
    const orig = data;
    var scratch: [128]u8 = undefined;
    permuteBlocks(&data, 16, &packus_epi16_order_sse41, &scratch);
    try testing.expectEqualSlices(u8, &orig, &data);
}

test "permuteBlocks reorders blocks per a non-trivial order" {
    // 4 blocks of 2 bytes; order swaps pairs.
    var data = [_]u8{ 10, 11, 20, 21, 30, 31, 40, 41 };
    const order = [_]usize{ 2, 3, 0, 1 };
    var scratch: [8]u8 = undefined;
    permuteBlocks(&data, 2, &order, &scratch);
    try testing.expectEqualSlices(u8, &[_]u8{ 30, 31, 40, 41, 10, 11, 20, 21 }, &data);
}

test "weightIndexScrambled matches the C++ formula" {
    // fc_0-like: PaddedInputDimensions=1024, OutputDimensions=32.
    try testing.expectEqual(@as(usize, 0), weightIndexScrambled(0, 1024, 32));
    try testing.expectEqual(@as(usize, 1), weightIndexScrambled(1, 1024, 32));
    // i=4 -> (1)%256*128 + 0 + 0 = 128
    try testing.expectEqual(@as(usize, 128), weightIndexScrambled(4, 1024, 32));
    // i=1024 -> (256)%256*128 + 4 + 0 = 0 + 4 = 4
    try testing.expectEqual(@as(usize, 4), weightIndexScrambled(1024, 1024, 32));
}
