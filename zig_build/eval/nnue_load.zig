// Native NNUE parameter deserialization — the post-src/ replacement for the C++
// read_parameters chain (src/nnue/*.h) that Network::load runs over the .nnue blob.
// This is phase B's one genuine BUILD item (the rest of the flip is the atomic
// accessor switch); it is ported incrementally + shadow-verified against the live
// C++ parse, member by member, before the switch.
//
// Fire B1.1: the signed-LEB128 reader — the foundation read_leb_128 uses for the
// feature-transformer biases/weights/psqtWeights and the affine-layer parameters.
//
// The .nnue is loaded as one in-memory blob, so the reader is a cursor over a byte
// slice rather than a std::istream. Mirrors src/nnue/nnue_common.h read_leb_128:
// a "COMPRESSED_LEB128" magic + little-endian u32 byte budget, then one or more
// arrays decoded out of that shared budget; the budget must hit exactly zero.

const std = @import("std");

/// src/nnue/nnue_common.h Leb128MagicString (Leb128MagicStringSize = 17, no NUL).
pub const leb128_magic = "COMPRESSED_LEB128";

pub const Leb128Error = error{ BadMagic, Truncated, BudgetNotEmpty };

/// Cursor over the .nnue blob for a read_leb_128 group (magic + budget + arrays).
pub const Leb128Reader = struct {
    data: []const u8,
    pos: usize,
    bytes_left: u32,

    /// Consume the magic string + the u32 byte budget at `pos`.
    pub fn begin(data: []const u8, pos: usize) Leb128Error!Leb128Reader {
        if (pos + leb128_magic.len + 4 > data.len) return error.Truncated;
        if (!std.mem.eql(u8, data[pos..][0..leb128_magic.len], leb128_magic))
            return error.BadMagic;
        const after_magic = pos + leb128_magic.len;
        const bytes_left = std.mem.readInt(u32, data[after_magic..][0..4], .little);
        return .{ .data = data, .pos = after_magic + 4, .bytes_left = bytes_left };
    }

    /// Decode out.len signed values (truncated to IntType), advancing the cursor and
    /// drawing from the shared byte budget. Canonical signed LEB128: 7 bits/byte,
    /// high bit = continue, second-highest bit of the final byte = sign. Matches the
    /// C++ read_leb_128_detail for every in-range value the .nnue actually stores.
    pub fn readArray(self: *Leb128Reader, comptime IntType: type, out: []IntType) Leb128Error!void {
        comptime std.debug.assert(@typeInfo(IntType).int.signedness == .signed);
        comptime std.debug.assert(@bitSizeOf(IntType) <= 32);

        var i: usize = 0;
        while (i < out.len) : (i += 1) {
            var result: i64 = 0;
            var shift: usize = 0;
            while (true) {
                if (self.pos >= self.data.len or self.bytes_left == 0) return error.Truncated;
                const byte = self.data[self.pos];
                self.pos += 1;
                self.bytes_left -= 1;
                if (shift < 64)
                    result |= @as(i64, byte & 0x7f) << @intCast(shift);
                shift += 7;
                if (byte & 0x80 == 0) {
                    if (shift < 64 and (byte & 0x40) != 0)
                        result |= @as(i64, -1) << @intCast(shift); // sign-extend
                    break;
                }
            }
            out[i] = @truncate(result);
        }
    }

    /// The C++ asserts the whole byte budget was consumed (assert(bytes_left == 0)).
    pub fn finish(self: *const Leb128Reader) Leb128Error!void {
        if (self.bytes_left != 0) return error.BudgetNotEmpty;
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

// Build a read_leb_128 group blob: magic + u32 budget + the raw LEB128 bytes.
fn group(comptime body: []const u8) [leb128_magic.len + 4 + body.len]u8 {
    var buf: [leb128_magic.len + 4 + body.len]u8 = undefined;
    @memcpy(buf[0..leb128_magic.len], leb128_magic);
    std.mem.writeInt(u32, buf[leb128_magic.len..][0..4], body.len, .little);
    @memcpy(buf[leb128_magic.len + 4 ..], body);
    return buf;
}

test "begin rejects a bad magic string" {
    var blob = group(&[_]u8{0x00});
    blob[0] = 'X';
    try testing.expectError(error.BadMagic, Leb128Reader.begin(&blob, 0));
}

test "decodes canonical signed-LEB128 vectors (i16)" {
    // value -> bytes: 0,-1,127,-128,300,-300 and i16 extremes.
    const body = [_]u8{
        0x00, // 0
        0x7f, // -1
        0xFF, 0x00, // 127
        0x80, 0x7f, // -128
        0xAC, 0x02, // 300
        0xD4, 0x7d, // -300
        0xFF, 0xFF, 0x01, // 32767
        0x80, 0x80, 0x7e, // -32768
    };
    var blob = group(&body);
    var r = try Leb128Reader.begin(&blob, 0);
    var out: [8]i16 = undefined;
    try r.readArray(i16, &out);
    try testing.expectEqualSlices(i16, &[_]i16{ 0, -1, 127, -128, 300, -300, 32767, -32768 }, &out);
    try r.finish();
}

test "decodes 32-bit values and reports a partial budget" {
    const body = [_]u8{
        0x80, 0x80, 0x80, 0x80, 0x08, // 2147483648 truncates to i32 min (-2147483648)
        0xFF, 0xFF, 0xFF, 0xFF, 0x07, // 2147483647
    };
    var blob = group(&body);
    var r = try Leb128Reader.begin(&blob, 0);
    var out: [2]i32 = undefined;
    try r.readArray(i32, &out);
    try testing.expectEqual(@as(i32, -2147483648), out[0]);
    try testing.expectEqual(@as(i32, 2147483647), out[1]);
    try r.finish();

    // Reading fewer than the budget leaves a non-empty budget → finish() complains.
    var r2 = try Leb128Reader.begin(&blob, 0);
    var one: [1]i32 = undefined;
    try r2.readArray(i32, &one);
    try testing.expectError(error.BudgetNotEmpty, r2.finish());
}

test "round-trips every i16 through a hand-rolled encoder" {
    var body = std.ArrayListUnmanaged(u8).empty;
    defer body.deinit(testing.allocator);
    var v: i32 = -32768;
    while (v <= 32767) : (v += 1) {
        try encodeSigned(testing.allocator, &body, @as(i16, @intCast(v)));
    }
    var buf = try testing.allocator.alloc(u8, leb128_magic.len + 4 + body.items.len);
    defer testing.allocator.free(buf);
    @memcpy(buf[0..leb128_magic.len], leb128_magic);
    std.mem.writeInt(u32, buf[leb128_magic.len..][0..4], @intCast(body.items.len), .little);
    @memcpy(buf[leb128_magic.len + 4 ..], body.items);

    var r = try Leb128Reader.begin(buf, 0);
    const out = try testing.allocator.alloc(i16, 65536);
    defer testing.allocator.free(out);
    try r.readArray(i16, out);
    try r.finish();
    for (out, 0..) |got, idx| {
        try testing.expectEqual(@as(i16, @intCast(@as(i32, -32768) + @as(i32, @intCast(idx)))), got);
    }
}

// Reference signed-LEB128 encoder (test-only), matching the wikipedia algorithm.
fn encodeSigned(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: i16) !void {
    var more = true;
    var v: i32 = value;
    while (more) {
        var byte: u8 = @intCast(@as(u32, @bitCast(v)) & 0x7f);
        v >>= 7; // arithmetic shift
        if ((v == 0 and (byte & 0x40) == 0) or (v == -1 and (byte & 0x40) != 0)) {
            more = false;
        } else {
            byte |= 0x80;
        }
        try out.append(alloc, byte);
    }
}
