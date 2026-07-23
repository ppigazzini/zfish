// Provide the signed-LEB128 decode of the .nnue parse.
//
// Split from nnue_parse.zig on the 500-line lint: the decoder is the one parse
// primitive with no knowledge of the .nnue section layout, so it carries its own
// reference encoder and bound tests. Mirror read_leb_128_detail (nnue_common.h):
// 7 bits per byte, shift masked to 32, sign-extend when the final shift < 32 and
// bit 0x40 is set.

const std = @import("std");

// Decode `count` signed-LEB128 values from `src` into `out`, returning the number of source
// bytes consumed, or null if `src` runs out first. Mirror read_leb_128_detail: 7 bits per byte,
// shift masked to 32, sign-extend when the final shift < 32 and bit 0x40 is set.
//
// The bound is load-bearing: a .nnue file states its section length and its value count
// independently, so a corrupt one can promise more values than it carries. ReleaseFast checks
// neither the slice nor the count, so without this the decode walks off the section.
pub fn decodeLeb(comptime IntType: type, src: []const u8, out: []IntType, count: usize) ?usize {
    std.debug.assert(out.len >= count);
    const UnsignedT = @Int(.unsigned, @bitSizeOf(IntType));
    // A value of IntType terminates within max_len bytes unless the stream is malformed.
    const max_len = (@bitSizeOf(IntType) + 6) / 7;
    // Sign-extension masks per encoded length: ~((1 << 7*len) - 1) while 7*len < 32,
    // matching the loop's `shift < 32` guard (a full-width value carries its sign bit).
    const sign_masks: [max_len + 1]u32 = comptime blk: {
        var m: [max_len + 1]u32 = undefined;
        m[0] = 0;
        for (1..max_len + 1) |len| {
            const shift = 7 * len;
            m[len] = if (shift < 32) ~((@as(u32, 1) << shift) - 1) else 0;
        }
        break :blk m;
    };
    var pos: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        // Decode a value that fits two bytes branch-free: select the second byte's
        // contribution and the encoded length by the first byte's continuation bit
        // arithmetically instead of testing it -- that test is the one data-dependent
        // branch of the whole parse (the 1-vs-2-byte encoding mix is noise to the
        // predictor; measured 4.49M mispredicts over the net load, 11% of the bench's
        // total). Chaining ALL max_len lanes this way loses: it pays every lane on
        // every value (+202M instructions, +2.1%) where the loop exits after ~1.2
        // bytes. Two lanes cover the near-universal case, and the fall-through test to
        // the loop stays a branch precisely because it is skewed enough to predict.
        // The byte math is the loop's exactly, so any value the loop decodes within
        // two bytes decodes to the same bits and length here.
        if (pos + 2 <= src.len) {
            const b0 = src[pos];
            const b1 = src[pos + 1];
            const cont: u32 = b0 >> 7;
            if ((cont & (b1 >> 7)) == 0) {
                var result: u32 = @as(u32, b0 & 0x7f);
                result |= (@as(u32, b1 & 0x7f) << 7) & (0 -% cont);
                const len: usize = 1 + cont;
                const sign_byte = src[pos + len - 1];
                result |= sign_masks[len] & (0 -% (@as(u32, sign_byte >> 6) & 1));
                out[i] = @bitCast(@as(UnsignedT, @truncate(result)));
                pos += len;
                continue;
            }
        }
        var result: u32 = 0;
        // Unbounded shift like upstream's `usize shift` (nnue_common.h:200): a u6 wraps at 64,
        // so past 9 continuation bytes `shift < 32` would wrongly re-enable sign-extension.
        // Valid (canonical) LEB is <=5 bytes, so this only differs on malformed input.
        var shift: usize = 0;
        while (true) {
            if (pos >= src.len) return null;
            const byte = src[pos];
            pos += 1;
            result |= @as(u32, byte & 0x7f) << @intCast(shift % 32);
            shift += 7;
            if (byte & 0x80 == 0) {
                if (shift < 32 and (byte & 0x40) != 0) {
                    // sign-extend: result | ~((1 << shift) - 1)
                    const mask = ~((@as(u32, 1) << @intCast(shift)) - 1);
                    result |= mask;
                }
                out[i] = @bitCast(@as(UnsignedT, @truncate(result)));
                break;
            }
        }
    }
    return pos;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

// Encode a reference signed-LEB128 value (standard) to round-trip against the decoder.
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
    const consumed = decodeLeb(i16, buf.items, &out, vals16.len).?;
    try testing.expectEqual(buf.items.len, consumed);
    try testing.expectEqualSlices(i16, &vals16, &out);

    const vals32 = [_]i32{ 0, 1, -1, 123456, -123456, 2147483647, -2147483648 };
    var buf2 = std.ArrayList(u8).empty;
    defer buf2.deinit(a);
    for (vals32) |v| try encodeOne(i32, v, &buf2, a);
    var out2: [vals32.len]i32 = undefined;
    _ = decodeLeb(i32, buf2.items, &out2, vals32.len).?;
    try testing.expectEqualSlices(i32, &vals32, &out2);
}

test "decodeLeb reports exhaustion instead of reading past its slice" {
    const a = testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    for ([_]i16{ 1, 2, 3 }) |v| try encodeOne(i16, v, &buf, a);

    // Ask for more values than the source carries: the corrupt-file shape, where the section
    // length and the value count disagree.
    var out: [8]i16 = undefined;
    try testing.expectEqual(@as(?usize, null), decodeLeb(i16, buf.items, &out, 8));

    // Truncating mid-stream must also report exhaustion, not decode a short value.
    try testing.expectEqual(@as(?usize, null), decodeLeb(i16, buf.items[0..2], &out, 3));

    // An empty source with work to do is exhausted immediately; with no work it consumes zero.
    try testing.expectEqual(@as(?usize, null), decodeLeb(i16, &.{}, &out, 1));
    try testing.expectEqual(@as(?usize, 0), decodeLeb(i16, &.{}, &out, 0));

    // The exact-fit case still succeeds, so the bound did not cost a legal decode.
    try testing.expectEqual(@as(?usize, buf.items.len), decodeLeb(i16, buf.items, &out, 3));
}
