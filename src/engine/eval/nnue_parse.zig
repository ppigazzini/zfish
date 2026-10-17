// Provide the .nnue parse primitives.
//
// Parse the .nnue file into its (already-permuted) weight memory. These are the
// building blocks of that parse, matching src/nnue exactly:
//
//   * the feature-transformer sections -- plain little-endian since SFNNv18, which
//     removed upstream's LEB128 codec (read/write_leb_128) along with the i16 psq rows;
//   * permuteBlocks -- the byte-block reorder of permute<> (nnue_feature_
//     transformer.h). zfish's feature transform writes its int8 output in natural
//     chunk order (nnue_accumulator.transform), never the arch-specific packus
//     lane-interleave that upstream's permute<> compensates for, so the FT weights
//     need NO reorder on ANY tier (the AVX512 build is bit-exact unpermuted).
//     permuteBlocks is therefore unused by the live parse -- kept for structural
//     parity and exercised only in tests.
//   * weightIndexScrambled -- get_weight_index_scrambled (affine_transform.h),
//     the SSSE3 weight index permutation the layer parse writes through and the
//     Zig propagate already reads back. On the AVX2 pair-activation tier
//     (`scrambled_activations`) the fc_1/fc_2 parse additionally folds the 128-bit-lane
//     interleave of the paired activation packs into the weight index, exactly as
//     upstream's unconditional branch of the same function. The interleave is per vector
//     WIDTH: the AVX-512 packs have four lanes where AVX2's have two.

const std = @import("std");
const builtin = @import("builtin");
const dims = @import("nnue_dimensions");

/// The SSE4.1 packus lane order (which happens to be the identity {0..7}). A test fixture for
/// permuteBlocks only: the live parse never permutes on any tier (see the header), so no target
/// swaps this -- it does not gate correctness.
pub const packus_epi16_order_sse41 = [8]usize{ 0, 1, 2, 3, 4, 5, 6, 7 };

/// Reorder blocks per permute<BlockSize>: `order.len` blocks of `block_size` bytes
/// within each (block_size * order.len)-byte chunk of `data`.
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

const avx512_activations = builtin.target.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.target.cpu.features, .avx512f);

/// Mirror upstream's USE_PAIR_ACTIVATIONS (simd.h, b52f0147) -- every AVX2-or-better x86
/// tier, AVX-512 and AVXVNNI included, since all three pack their activations. This
/// chooses the paired activation KERNEL in nnue_inference.zig, which produces the squared
/// and linear activations together off shared loads.
pub const pair_activations = builtin.target.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.target.cpu.features, .avx2);

/// Scramble wherever the activations are paired: every packing kernel narrows per 128-bit
/// LANE, so the output bytes land interleaved and the next layer's weights must be
/// permuted to match. The two flags are one condition upstream (b52f0147 folded
/// USE_SCRAMBLED_ACTIVATIONS into USE_PAIR_ACTIVATIONS); they stay separate names here
/// because the parse keys the weight INDEX off this one and nnue_inference keys the KERNEL
/// off the other, and the bench signature pins that the two agree. What the tier still
/// decides is the interleave ITSELF -- see pairScrambledInputIndex.
pub const scrambled_activations = pair_activations;

/// Map an input index to where the paired activation packs put its value, and rearrange the
/// next layer's weights by that map instead of issuing a lane-restoring permute in the packs
/// (upstream get_weight_index_scrambled, affine_transform.h). Both narrows work per 128-bit
/// lane, so within each 32-byte block the eight 4-byte chunks land interleaved -- but by a
/// DIFFERENT map per width, because the lane count differs: vpackssdw at 256 bits has two
/// lanes (chunk k -> (k%2)*4 + k/2), at 512 bits four (chunk k -> (k%4)*2 + k/4). Inverting
/// the two silently corrupts the fc_1/fc_2 weights.
fn pairScrambledInputIndex(input_index: usize) usize {
    const block = input_index / 32;
    const chunk = (input_index % 32) / 4;
    return block * 32 + pairScrambledChunk(pair_lane_count, chunk) * 4 + input_index % 4;
}

/// 128-bit lanes per pack: four at AVX-512 width, two at AVX2's.
const pair_lane_count: usize = if (avx512_activations) 4 else 2;

/// Place 4-byte chunk `chunk` of a 32-byte block where a `lanes`-lane narrowing puts it.
///
/// The closed form is shared but the two tiers REACH it differently, so read it as a result
/// and not as a mechanism: AVX-512 runs one `vpackssdw` over both halves across four lanes
/// and then an in-order `vpmovswb`, while AVX2 runs two `vpackssdw` and a `vpacksswb` across
/// two lanes, and the composite of those three lands on the same shape one lane count down.
/// What both preserve is that a chunk stays contiguous and keeps its internal order, which
/// is what lets the caller pass `input_index % 4` straight through.
fn pairScrambledChunk(comptime lanes: usize, chunk: usize) usize {
    return (chunk % lanes) * (8 / lanes) + chunk / lanes;
}

/// Compute get_weight_index_scrambled(i): the SSSE3 affine weight index permutation.
/// `scrambled_input` adds the pair-activation lane interleave to the input index first
/// (upstream's ScrambledInput template flag -- fc_1/fc_2 on the pair tier only).
pub fn weightIndexScrambled(i: usize, padded_input: usize, output_dims: usize, scrambled_input: bool) usize {
    const input_index = if (scrambled_input) pairScrambledInputIndex(i % padded_input) else i % padded_input;
    return input_index / 4 * output_dims * 4 + i / padded_input * 4 + input_index % 4;
}

// ---- feature transformer parse ---------------------------------------------

/// Write each region where nnue_dimensions says it lives. The accessors in nnue_ft.zig read
/// it back from the same declarations, so the writer and the reader cannot drift apart --
/// see that module's header for what the two derivations used to risk.
const half_dimensions = dims.half_dimensions;
const psq_feature_dimensions = dims.psq_feature_dimensions;
const threat_dimensions = dims.threat_dimensions;
const pp_dimensions = dims.pp_dimensions;
const threat_and_pp_dimensions = dims.threat_and_pp_dimensions;

const biases_count = dims.biases_count;
const psq_weights_count = dims.psq_weights_count;
const threat_weights_count = dims.threat_weights_count;

const threat_only_weights_count = dims.threat_only_weights_count;
const pp_only_weights_count = dims.pp_only_weights_count;

const ft_total_bytes = dims.ft_total_bytes;
const biases_off = dims.biases_off;
const weights_off = dims.weights_off;
const threat_weights_off = dims.threat_weights_off;
const pp_weights_off = dims.pp_weights_off;

fn dstSlice(comptime T: type, dst: []u8, off: usize, count: usize) []T {
    @setRuntimeSafety(true); // check the @alignCast and the arena bound, not just the offsets
    const bytes: []align(@alignOf(T)) u8 = @alignCast(dst[off .. off + count * @sizeOf(T)]);
    return std.mem.bytesAsSlice(T, bytes);
}

/// Copy one little-endian section of `out.len` values from the start of `blob` into `out`
/// -- upstream read_little_endian(stream, out, count). Return the bytes consumed, or null if
/// the blob ends first.
fn readLeSection(comptime T: type, blob: []const u8, out: []T) ?usize {
    @setRuntimeSafety(true); // untrusted file, startup-only -- see parseFeatureTransformer
    const n = out.len * @sizeOf(T);
    if (blob.len < n) return null;
    @memcpy(std.mem.sliceAsBytes(out), blob[0..n]);
    if (comptime builtin.target.cpu.arch.endian() == .big) {
        for (out) |*v| v.* = @byteSwap(v.*);
    }
    return n;
}

/// Parse the feature-transformer blob into `dst` (the FeatureTransformer memory
/// layout). No permute -- the transform reads FT weights in natural order on every tier.
/// Return the number of blob bytes consumed, or null on malformed input.
pub fn parseFeatureTransformer(blob: []const u8, dst: []u8) ?usize {
    // Keep runtime safety on here even in ReleaseFast. `blob` is whatever bytes the file
    // named by EvalFile happened to contain, and the shipped build otherwise checks no
    // slice bound, cast or overflow at all. The parse runs once at startup and never on
    // the per-node path, so the checks cost no search throughput. They are a backstop,
    // not the contract: every short-blob test below rejects a malformed file
    // gracefully, and only a bound this function failed to state can reach a trap.
    @setRuntimeSafety(true);
    // Skip the leading u32 component hash (Detail::read_parameters). Check it is there first:
    // a file shorter than the hash would make the very first section slice out of range.
    if (blob.len < 4) return null;
    var pos: usize = 4;
    // Follow the SFNNv18 read order: biases, threatWeights, ppWeights, weights, every one a
    // plain little-endian array. The threat and pp weight sections are read separately but
    // written into the one contiguous threatAndPp region (pp right after threat), so a
    // single index addresses either at runtime.
    pos += readLeSection(i16, blob[pos..], dstSlice(i16, dst, biases_off, biases_count)) orelse return null;
    pos += readLeSection(i8, blob[pos..], dstSlice(i8, dst, threat_weights_off, threat_only_weights_count)) orelse return null;
    pos += readLeSection(i8, blob[pos..], dstSlice(i8, dst, pp_weights_off, pp_only_weights_count)) orelse return null;
    pos += readLeSection(i8, blob[pos..], dstSlice(i8, dst, weights_off, psq_weights_count)) orelse return null;
    return pos;
}

/// List the three written weight regions (offset, byte length), used to compare a parse
/// against a reference while skipping the alignment padding between them.
const FtRegion = struct { off: usize, len: usize };
pub const ft_regions = [_]FtRegion{
    .{ .off = biases_off, .len = biases_count * 2 },
    .{ .off = weights_off, .len = psq_weights_count * 1 },
    .{ .off = threat_weights_off, .len = threat_weights_count * 1 },
};

/// Parse `blob` into `scratch` and confirm each weight region matches `reference`
/// (a reference FeatureTransformer memory image). Returns true iff bit-identical.
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

/// Parse one affine layer's parameters at the start of `blob`: biases
/// (OutputDimensions int32, little-endian, linear) then weights (int8, written
/// through the SSSE3 scramble -- plus the pair-activation input interleave when
/// `scrambled_input` is set). OutputDimensions and PaddedInputDimensions are
/// derived from the destination sizes (biases_dst.len/4 and weights_dst.len /
/// OutputDimensions). Returns the bytes consumed.
pub fn parseLayer(blob: []const u8, biases_dst: []u8, weights_dst: []u8, scrambled_input: bool) ?usize {
    @setRuntimeSafety(true); // untrusted file, startup-only -- see parseFeatureTransformer
    const output_dims = biases_dst.len / @sizeOf(i32);
    if (output_dims == 0) return null;
    if (blob.len < biases_dst.len + weights_dst.len) return null;
    // Copy the biases: int32 little-endian == native bytes on x86.
    @memcpy(biases_dst, blob[0..biases_dst.len]);
    var pos = biases_dst.len;
    const n = weights_dst.len; // int8 weights
    const padded_input = n / output_dims;
    for (0..n) |i| {
        weights_dst[weightIndexScrambled(i, padded_input, output_dims, scrambled_input)] = blob[pos + i];
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

/// Append `values` as one little-endian section -- upstream write_little_endian.
fn appendLeSection(comptime T: type, values: []const T, out: *Bytes, a: std.mem.Allocator) !void {
    if (comptime builtin.target.cpu.arch.endian() == .big) {
        for (values) |v| {
            var le: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &le, v, .little);
            try out.appendSlice(a, &le);
        }
        return;
    }
    try out.appendSlice(a, std.mem.sliceAsBytes(values));
}

/// Serialize FeatureTransformer::write_parameters preceded by Detail::write_parameters'
/// u32 hash. The live parse never permutes on any tier (see the header), so there is no
/// unpermute. Member
/// write order MUST mirror parseFeatureTransformer (the file / upstream layout):
/// biases (i16), threatWeights (i8), ppWeights (i8), weights (i8), all little-endian.
/// The threat and pp weight sections are stored contiguously (pp after threat) but
/// written as separate stream sections.
pub fn serializeFeatureTransformer(
    ft: []const u8,
    hash_value: u32,
    out: *Bytes,
    a: std.mem.Allocator,
) !void {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, hash_value, .little);
    try out.appendSlice(a, &hdr);

    try appendLeSection(i16, constSlice(i16, ft, biases_off, biases_count), out, a);
    try appendLeSection(i8, constSlice(i8, ft, threat_weights_off, threat_only_weights_count), out, a);
    try appendLeSection(i8, constSlice(i8, ft, pp_weights_off, pp_only_weights_count), out, a);
    try appendLeSection(i8, constSlice(i8, ft, weights_off, psq_weights_count), out, a);
}

/// Serialize AffineTransform::write_parameters: biases (int32 LE) then weights in the file's
/// linear order, recovered from the scrambled storage via get_weight_index. Reading back
/// through the SAME index map the parse wrote through inverts it, so `scrambled_input`
/// must match the parse's flag for the layer.
fn serializeLayerOne(biases: []const u8, weights: []const u8, scrambled_input: bool, out: *Bytes, a: std.mem.Allocator) !void {
    try out.appendSlice(a, biases);
    const output_dims = biases.len / @sizeOf(i32);
    const n = weights.len;
    const padded_input = n / output_dims;
    for (0..n) |i| {
        try out.append(a, weights[weightIndexScrambled(i, padded_input, output_dims, scrambled_input)]);
    }
}

/// Serialize NetworkArchitecture::write_parameters preceded by Detail's u32 hash. The
/// activations carry no parameters, so only fc_0/fc_1/fc_2 are written. fc_1/fc_2 read
/// paired-activation output on the pair tier, so their stored weights carry the extra
/// interleave and are exported back through it -- the emitted bytes stay tier-invariant.
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
    for (0..3) |idx| {
        try serializeLayerOne(biases[idx], weights[idx], scrambled_activations and idx > 0, out, a);
    }
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "permuteBlocks identity leaves data unchanged" {
    var data: [128]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);
    const orig = data;
    var scratch: [128]u8 = undefined;
    permuteBlocks(&data, 16, &packus_epi16_order_sse41, &scratch);
    try testing.expectEqualSlices(u8, &orig, &data);
}

test "permuteBlocks reorders blocks per a non-trivial order" {
    // Use 4 blocks of 2 bytes; order swaps pairs.
    var data = [_]u8{ 10, 11, 20, 21, 30, 31, 40, 41 };
    const order = [_]usize{ 2, 3, 0, 1 };
    var scratch: [8]u8 = undefined;
    permuteBlocks(&data, 2, &order, &scratch);
    try testing.expectEqualSlices(u8, &[_]u8{ 30, 31, 40, 41, 10, 11, 20, 21 }, &data);
}

test "weightIndexScrambled matches the upstream weight-scramble formula" {
    // Model fc_0-like: PaddedInputDimensions=1024, OutputDimensions=32.
    try testing.expectEqual(@as(usize, 0), weightIndexScrambled(0, 1024, 32, false));
    try testing.expectEqual(@as(usize, 1), weightIndexScrambled(1, 1024, 32, false));
    // i=4 -> (1)%256*128 + 0 + 0 = 128
    try testing.expectEqual(@as(usize, 128), weightIndexScrambled(4, 1024, 32, false));
    // i=1024 -> (256)%256*128 + 4 + 0 = 0 + 4 = 4
    try testing.expectEqual(@as(usize, 4), weightIndexScrambled(1024, 1024, 32, false));
}

test "the pair interleave matches upstream's map at BOTH pack widths" {
    // Both arms of upstream get_weight_index_scrambled, on every host: the chunk map is
    // parameterised, so the tier the build targets decides only which one runs live.
    // Two lanes (AVX2): chunk k -> (k%2)*4 + k/2, upstream's #else arm.
    for ([8]usize{ 0, 4, 1, 5, 2, 6, 3, 7 }, 0..) |want, chunk|
        try testing.expectEqual(want, pairScrambledChunk(2, chunk));
    // Four lanes (AVX-512): chunk k -> (k%4)*2 + k/4, upstream's USE_AVX512 arm.
    for ([8]usize{ 0, 2, 4, 6, 1, 3, 5, 7 }, 0..) |want, chunk|
        try testing.expectEqual(want, pairScrambledChunk(4, chunk));
}

test "weightIndexScrambled's pair interleave matches the upstream ScrambledInput branch" {
    // Model fc_1-like: PaddedInputDimensions=64, OutputDimensions=32. Chunk k of a
    // 32-byte block moves to pairScrambledChunk(k) before the base formula; the
    // expectations below follow the tier's own map.
    const chunk_at = struct {
        fn f(chunk: usize) usize {
            return pairScrambledChunk(pair_lane_count, chunk);
        }
    }.f;
    // i=0: chunk 0 -> 0 at either width, so index 0*128 + 0 + 0.
    try testing.expectEqual(@as(usize, 0), weightIndexScrambled(0, 64, 32, true));
    // i=4: chunk 1 -> its mapped position, whose input_index is 4x that -> position*128.
    try testing.expectEqual(chunk_at(1) * 128, weightIndexScrambled(4, 64, 32, true));
    // i=8: chunk 2, same reading.
    try testing.expectEqual(chunk_at(2) * 128, weightIndexScrambled(8, 64, 32, true));
    // i=28: chunk 7 -> position 7 (a fixed point at both widths), same as unscrambled.
    try testing.expectEqual(weightIndexScrambled(28, 64, 32, false), weightIndexScrambled(28, 64, 32, true));
    // i=33: block 1 is interleaved independently; sublane and output offsets ride along.
    try testing.expectEqual(@as(usize, 32 / 4 * 128 + 1), weightIndexScrambled(33, 64, 32, true));

    // The map is a bijection on every input index (weights neither collide nor drop).
    // Typed @splat, not `[_]bool{false} ** 128`: Zig 0.17 rejects `**`
    // directly after `}` -- the cross-version idiom the master-compat lane guards.
    var seen: [128]bool = @splat(false);
    for (0..128) |i| {
        const idx = weightIndexScrambled(i, 128, 1, true);
        try testing.expect(!seen[idx]);
        seen[idx] = true;
    }
}

test "feature transformer layout offsets match the FeatureTransformer format" {
    try testing.expectEqual(@as(usize, 0), biases_off);
    try testing.expectEqual(@as(usize, 2048), weights_off);
    try testing.expectEqual(@as(usize, 46139392), threat_weights_off);
    try testing.expectEqual(@as(usize, 112052224), ft_total_bytes);
}

test "parseFeatureTransformer rejects a blob that ends inside a section" {
    // The hash, then a bias section one byte short: no section may be read past the blob.
    // The parse stops at the first section, so the destination need only hold that one.
    var dst: [biases_count * 2]u8 align(64) = @splat(0);
    const short: [4 + biases_count * 2 - 1]u8 = @splat(0);
    try testing.expectEqual(@as(?usize, null), parseFeatureTransformer(&short, &dst));
}

test "parseFeatureTransformer rejects a blob shorter than its component hash" {
    // Size these with @splat, not the `**` repeat operator: Zig 0.17 no longer accepts `**`,
    // and @splat compiles on both the pinned toolchain and master.
    var dst: [64]u8 = @splat(0);
    const filler: [3]u8 = @splat(0xAB);
    for ([_]usize{ 0, 1, 3 }) |n| {
        const short = filler[0..n];
        try testing.expectEqual(@as(?usize, null), parseFeatureTransformer(short, &dst));
    }
}
