// .nnue parse primitives.
//
// Parses the .nnue file into its (already-permuted) weight memory. These are the
// building blocks of that parse, matching src/nnue exactly:
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

// ---- feature transformer parse ---------------------------------------------

pub const leb_magic = "COMPRESSED_LEB128";
const cache_line = 64;

pub const half_dimensions: usize = 1024;
pub const psq_feature_dimensions: usize = 22528;
pub const threat_dimensions: usize = 60720;
pub const psqt_buckets: usize = 8;

fn roundUp(x: usize, a: usize) usize {
    return (x + a - 1) / a * a;
}

// Element counts of the five feature-transformer arrays.
pub const biases_count = half_dimensions; // i16
pub const psq_weights_count = half_dimensions * psq_feature_dimensions; // i16
pub const threat_weights_count = half_dimensions * threat_dimensions; // i8
pub const psqt_weights_count = psq_feature_dimensions * psqt_buckets; // i32
pub const threat_psqt_weights_count = threat_dimensions * psqt_buckets; // i32

// In-memory byte offsets (member order, each alignas(64)): biases, weights(psq),
// threatWeights, psqtWeights, threatPsqtWeights.
pub const biases_off = 0;
pub const weights_off = roundUp(biases_count * 2, cache_line);
pub const threat_weights_off = roundUp(weights_off + psq_weights_count * 2, cache_line);
pub const psqt_weights_off = roundUp(threat_weights_off + threat_weights_count * 1, cache_line);
pub const threat_psqt_weights_off = roundUp(psqt_weights_off + psqt_weights_count * 4, cache_line);
pub const ft_total_bytes = roundUp(threat_psqt_weights_off + threat_psqt_weights_count * 4, cache_line);

fn dstSlice(comptime T: type, dst: []u8, off: usize, count: usize) []T {
    const bytes: []align(@alignOf(T)) u8 = @alignCast(dst[off .. off + count * @sizeOf(T)]);
    return std.mem.bytesAsSlice(T, bytes);
}

// Parse one COMPRESSED_LEB128 section ([magic][u32 count][data]) of `out.len`
// values into `out`; return total section bytes consumed, or null if malformed.
fn readLebSection(comptime T: type, blob: []const u8, out: []T) ?usize {
    if (blob.len < leb_magic.len + 4) return null;
    if (!std.mem.eql(u8, blob[0..leb_magic.len], leb_magic)) return null;
    const count = std.mem.readInt(u32, blob[leb_magic.len..][0..4], .little);
    const data = blob[leb_magic.len + 4 ..];
    if (data.len < count) return null;
    if (decodeLeb(T, data, out, out.len) != count) return null;
    return leb_magic.len + 4 + count;
}

// Two arrays packed in one LEB section (read_leb_128(a, b)).
fn readLebSection2(comptime T: type, blob: []const u8, out1: []T, out2: []T) ?usize {
    if (blob.len < leb_magic.len + 4) return null;
    if (!std.mem.eql(u8, blob[0..leb_magic.len], leb_magic)) return null;
    const count = std.mem.readInt(u32, blob[leb_magic.len..][0..4], .little);
    const data = blob[leb_magic.len + 4 ..];
    if (data.len < count) return null;
    const used1 = decodeLeb(T, data, out1, out1.len);
    const used2 = decodeLeb(T, data[used1..], out2, out2.len);
    if (used1 + used2 != count) return null;
    return leb_magic.len + 4 + count;
}

// Parse the feature-transformer blob into `dst` (the FeatureTransformer memory
// layout). No permute -- PackusEpi16Order is the identity on the SSE4.1 target.
// Returns the number of blob bytes consumed, or null on malformed input.
pub fn parseFeatureTransformer(blob: []const u8, dst: []u8) ?usize {
    // Leading u32 component hash (Detail::read_parameters); skip.
    var pos: usize = 4;
    // Read order (upstream 7c7fe322e merge): biases, threatWeights, threatPsqtWeights, weights,
    // psqtWeights -- each i32 PSQT array is now its OWN leb section (base packed both into one,
    // after weights). Storage offsets are unchanged; only the stream order/framing moved.
    // 1. biases (LEB i16)
    pos += readLebSection(i16, blob[pos..], dstSlice(i16, dst, biases_off, biases_count)) orelse return null;
    // 2. threatWeights (raw little-endian i8)
    if (blob.len < pos + threat_weights_count) return null;
    @memcpy(dst[threat_weights_off .. threat_weights_off + threat_weights_count], blob[pos .. pos + threat_weights_count]);
    pos += threat_weights_count;
    // 3. threatPsqtWeights (LEB i32, own section)
    pos += readLebSection(i32, blob[pos..], dstSlice(i32, dst, threat_psqt_weights_off, threat_psqt_weights_count)) orelse return null;
    // 4. weights / psq weights (LEB i16)
    pos += readLebSection(i16, blob[pos..], dstSlice(i16, dst, weights_off, psq_weights_count)) orelse return null;
    // 5. psqtWeights (LEB i32, own section)
    pos += readLebSection(i32, blob[pos..], dstSlice(i32, dst, psqt_weights_off, psqt_weights_count)) orelse return null;
    return pos;
}

// The five written weight regions (offset, byte length), used to compare a parse
// against a reference while skipping the alignment padding between them.
const FtRegion = struct { off: usize, len: usize };
pub const ft_regions = [_]FtRegion{
    .{ .off = biases_off, .len = biases_count * 2 },
    .{ .off = weights_off, .len = psq_weights_count * 2 },
    .{ .off = threat_weights_off, .len = threat_weights_count * 1 },
    .{ .off = psqt_weights_off, .len = psqt_weights_count * 4 },
    .{ .off = threat_psqt_weights_off, .len = threat_psqt_weights_count * 4 },
};

// Parse `blob` into `scratch` and confirm each weight region matches `reference`
// (a reference FeatureTransformer memory image). Returns true iff bit-identical.
pub fn verifyFeatureTransformer(blob: []const u8, reference: []const u8, scratch: []u8) bool {
    if (reference.len < ft_total_bytes or scratch.len < ft_total_bytes) return false;
    if (parseFeatureTransformer(blob, scratch) == null) return false;
    for (ft_regions) |r| {
        if (!std.mem.eql(u8, scratch[r.off .. r.off + r.len], reference[r.off .. r.off + r.len]))
            return false;
    }
    return true;
}

// ---- affine layer parse -----------------------------------------------------

// Parse one affine layer's parameters at the start of `blob`: biases
// (OutputDimensions int32, little-endian, linear) then weights (int8, written
// through the SSSE3 scramble). OutputDimensions and PaddedInputDimensions are
// derived from the destination sizes (biases_dst.len/4 and weights_dst.len /
// OutputDimensions). Returns the bytes consumed.
pub fn parseLayer(blob: []const u8, biases_dst: []u8, weights_dst: []u8) ?usize {
    const output_dims = biases_dst.len / @sizeOf(i32);
    if (output_dims == 0) return null;
    if (blob.len < biases_dst.len + weights_dst.len) return null;
    // biases: int32 little-endian == native bytes on x86.
    @memcpy(biases_dst, blob[0..biases_dst.len]);
    var pos = biases_dst.len;
    const n = weights_dst.len; // int8 weights
    const padded_input = n / output_dims;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        weights_dst[weightIndexScrambled(i, padded_input, output_dims)] = blob[pos + i];
    }
    pos += n;
    return pos;
}

// ---- serialization (write_parameters) ---------------------------------------

const Bytes = std.ArrayList(u8);

fn constSlice(comptime T: type, src: []const u8, off: usize, count: usize) []const T {
    const bytes: []align(@alignOf(T)) const u8 = @alignCast(src[off .. off + count * @sizeOf(T)]);
    return std.mem.bytesAsSlice(T, bytes);
}

// Append one canonical signed-LEB128 value (write_leb_128, nnue_common.h).
fn encodeLebValue(comptime T: type, v: T, out: *Bytes, a: std.mem.Allocator) !void {
    var value: i64 = v;
    while (true) {
        const byte: u8 = @intCast(value & 0x7f);
        value >>= 7;
        const done = if (byte & 0x40 == 0) value == 0 else value == -1;
        if (done) {
            try out.append(a, byte);
            return;
        }
        try out.append(a, byte | 0x80);
    }
}

// Append a COMPRESSED_LEB128 section: magic, u32 byte-count, then the encoded
// values. `extra` (if non-empty) is encoded into the same section after `values`
// (the two-array write_leb_128(threatPsqt, psqt) overload).
fn encodeLebSection(
    comptime T: type,
    values: []const T,
    extra: []const T,
    out: *Bytes,
    a: std.mem.Allocator,
) !void {
    try out.appendSlice(a, leb_magic);
    const count_pos = out.items.len;
    try out.appendSlice(a, &[_]u8{ 0, 0, 0, 0 });
    const data_start = out.items.len;
    for (values) |v| try encodeLebValue(T, v, out, a);
    for (extra) |v| try encodeLebValue(T, v, out, a);
    const count: u32 = @intCast(out.items.len - data_start);
    std.mem.writeInt(u32, out.items[count_pos..][0..4], count, .little);
}

// FeatureTransformer::write_parameters preceded by Detail::write_parameters'
// u32 hash. PackusEpi16Order is the identity, so unpermute is a no-op. Member
// write order: biases (LEB i16), threatWeights (raw i8), weights (LEB i16),
// combined threatPsqtWeights++psqtWeights (LEB i32).
pub fn serializeFeatureTransformer(
    ft: []const u8,
    hash_value: u32,
    out: *Bytes,
    a: std.mem.Allocator,
) !void {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, hash_value, .little);
    try out.appendSlice(a, &hdr);

    try encodeLebSection(i16, constSlice(i16, ft, biases_off, biases_count), &.{}, out, a);
    try out.appendSlice(a, ft[threat_weights_off .. threat_weights_off + threat_weights_count]);
    try encodeLebSection(i16, constSlice(i16, ft, weights_off, psq_weights_count), &.{}, out, a);
    try encodeLebSection(
        i32,
        constSlice(i32, ft, threat_psqt_weights_off, threat_psqt_weights_count),
        constSlice(i32, ft, psqt_weights_off, psqt_weights_count),
        out,
        a,
    );
}

// AffineTransform::write_parameters: biases (int32 LE) then weights in the file's
// linear order, recovered from the scrambled storage via get_weight_index.
fn serializeLayerOne(biases: []const u8, weights: []const u8, out: *Bytes, a: std.mem.Allocator) !void {
    try out.appendSlice(a, biases);
    const output_dims = biases.len / @sizeOf(i32);
    const n = weights.len;
    const padded_input = n / output_dims;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try out.append(a, weights[weightIndexScrambled(i, padded_input, output_dims)]);
    }
}

// NetworkArchitecture::write_parameters preceded by Detail's u32 hash. The
// activations carry no parameters, so only fc_0/fc_1/fc_2 are written.
pub fn serializeLayer(
    hash_value: u32,
    biases: [3][]const u8,
    weights: [3][]const u8,
    out: *Bytes,
    a: std.mem.Allocator,
) !void {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, hash_value, .little);
    try out.appendSlice(a, &hdr);
    var idx: usize = 0;
    while (idx < 3) : (idx += 1) {
        try serializeLayerOne(biases[idx], weights[idx], out, a);
    }
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

test "weightIndexScrambled matches the upstream weight-scramble formula" {
    // fc_0-like: PaddedInputDimensions=1024, OutputDimensions=32.
    try testing.expectEqual(@as(usize, 0), weightIndexScrambled(0, 1024, 32));
    try testing.expectEqual(@as(usize, 1), weightIndexScrambled(1, 1024, 32));
    // i=4 -> (1)%256*128 + 0 + 0 = 128
    try testing.expectEqual(@as(usize, 128), weightIndexScrambled(4, 1024, 32));
    // i=1024 -> (256)%256*128 + 4 + 0 = 0 + 4 = 4
    try testing.expectEqual(@as(usize, 4), weightIndexScrambled(1024, 1024, 32));
}

test "feature transformer layout offsets match the FeatureTransformer format" {
    try testing.expectEqual(@as(usize, 0), biases_off);
    try testing.expectEqual(@as(usize, 2048), weights_off);
    try testing.expectEqual(@as(usize, 46139392), threat_weights_off);
    try testing.expectEqual(@as(usize, 108316672), psqt_weights_off);
    try testing.expectEqual(@as(usize, 109037568), threat_psqt_weights_off);
    try testing.expectEqual(@as(usize, 110980608), ft_total_bytes);
}
