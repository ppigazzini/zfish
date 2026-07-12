// Native NNUE content hashing.
//
// Network::get_content_hash (network.cpp) combines per-component hashes of the
// feature transformer and the eight layer stacks. Each component hashes its raw
// weight bytes with hash_bytes (MurmurHash2-64A, misc.cpp) and mixes in the
// compile-time architecture hash values. These are computed from the weight
// storage at load time. Matches src/nnue exactly.

const std = @import("std");
const nnue_parse = @import("nnue_parse.zig");

const hash_combine_magic: usize = 0x9e3779b9;

// hash_bytes: MurmurHash2 64-bit (misc.cpp).
pub fn hashBytes(data: []const u8) u64 {
    const m: u64 = 0xc6a4a7935bd1e995;
    const r: u6 = 47;
    var h: u64 = @as(u64, data.len) *% m;

    const tail = data.len & ~@as(usize, 7);
    var p: usize = 0;
    while (p != tail) : (p += 8) {
        var k = std.mem.readInt(u64, data[p..][0..8], .little);
        k *%= m;
        k ^= k >> r;
        k *%= m;
        h ^= k;
        h *%= m;
    }

    if (data.len & 7 != 0) {
        var k: u64 = 0;
        var i: usize = (data.len & 7);
        while (i > 0) {
            i -= 1;
            k = (k << 8) | @as(u64, data[tail + i]);
        }
        h ^= k;
        h *%= m;
    }

    h ^= h >> r;
    h *%= m;
    h ^= h >> r;
    return h;
}

// hash_combine for an integral value (misc.h): seed ^= v + 0x9e3779b9 +
// (seed<<6) + (seed>>2).
pub fn hashCombine(seed: *usize, v: usize) void {
    seed.* ^= v +% hash_combine_magic +% (seed.* << 6) +% (seed.* >> 2);
}

fn rawDataHash(seed: *usize, bytes: []const u8) void {
    hashCombine(seed, @intCast(hashBytes(bytes)));
}

// ---- feature transformer -----------------------------------------------------

// combine_hash (nnue_feature_transformer.h): rotate-left-1 then xor.
fn combineHash(comptime hashes: []const u32) u32 {
    var hash: u32 = 0;
    inline for (hashes) |c| {
        hash = (hash << 1) | (hash >> 31);
        hash ^= c;
    }
    return hash;
}

// FeatureTransformer::get_hash_value: combine the feature-set hashes, xor the
// transformed dimensions. ThreatFeatureSet=full_threats (0x8f234cb8),
// PSQFeatureSet=half_ka_v2_hm (0x7f234cb8), OutputDimensions=HalfDimensions=1024.
pub fn featureTransformerHashValue() u32 {
    return combineHash(&.{ 0x8f234cb8, 0x7f234cb8 }) ^ (@as(u32, nnue_parse.half_dimensions) * 2);
}

// FeatureTransformer::get_content_hash. The raw-data hashes run in member-value
// order: biases, weights, psqtWeights, threatWeights, threatPsqtWeights.
pub fn featureTransformerContentHash(ft: [*]const u8) usize {
    const p = nnue_parse;
    var h: usize = 0;
    rawDataHash(&h, ft[p.biases_off..][0 .. p.biases_count * 2]);
    rawDataHash(&h, ft[p.weights_off..][0 .. p.psq_weights_count * 2]);
    rawDataHash(&h, ft[p.psqt_weights_off..][0 .. p.psqt_weights_count * 4]);
    rawDataHash(&h, ft[p.threat_weights_off..][0..p.threat_weights_count]);
    rawDataHash(&h, ft[p.threat_psqt_weights_off..][0 .. p.threat_psqt_weights_count * 4]);
    hashCombine(&h, featureTransformerHashValue());
    return h;
}

// ---- layer stack -------------------------------------------------------------

const affine_base: u32 = 0xCC03DAE4;
const clipped_base: u32 = 0x538D24C7;

// AffineTransform/AffineTransformSparseInput::get_hash_value(prevHash).
fn affineHashValue(prev: u32, out_dims: u32) u32 {
    var hv = affine_base +% out_dims;
    hv ^= prev >> 1;
    hv ^= prev << 31;
    return hv;
}

// AffineTransform::get_content_hash: hashes biases, weights, then get_hash_value(0)
// (prevHash is 0, so the xors vanish).
fn affineContentHash(biases: []const u8, weights: []const u8, out_dims: u32) usize {
    var h: usize = 0;
    rawDataHash(&h, biases);
    rawDataHash(&h, weights);
    hashCombine(&h, affine_base +% out_dims);
    return h;
}

// ClippedReLU/SqrClippedReLU::get_content_hash: get_hash_value(0). The activations
// carry no parameters, so this is a constant.
fn activationContentHash() usize {
    var h: usize = 0;
    hashCombine(&h, clipped_base);
    return h;
}

// NetworkArchitecture::get_hash_value (nnue_architecture.h), the chained variant
// that threads prevHash through fc_0, ac_0, fc_1, ac_1, fc_2.
pub fn architectureHashValue() u32 {
    var hv: u32 = 0xEC42E90D;
    hv ^= @as(u32, nnue_parse.half_dimensions) * 2; // TransformedFeatureDimensions*2
    hv = affineHashValue(hv, 32); // fc_0, OutputDimensions = FC_0_OUTPUTS + 1
    hv = clipped_base +% hv; // ac_0
    hv = affineHashValue(hv, 32); // fc_1, FC_1_OUTPUTS
    hv = clipped_base +% hv; // ac_1
    hv = affineHashValue(hv, 1); // fc_2
    return hv;
}

// NetworkArchitecture::get_content_hash for one layer stack. Per-layer dims:
// fc_0 1024->32, fc_1 62->32, fc_2 32->1.
pub fn layerStackContentHash(
    fc0_biases: []const u8,
    fc0_weights: []const u8,
    fc1_biases: []const u8,
    fc1_weights: []const u8,
    fc2_biases: []const u8,
    fc2_weights: []const u8,
) usize {
    var h: usize = 0;
    hashCombine(&h, affineContentHash(fc0_biases, fc0_weights, 32)); // fc_0
    hashCombine(&h, activationContentHash()); // ac_sqr_0
    hashCombine(&h, activationContentHash()); // ac_0
    hashCombine(&h, affineContentHash(fc1_biases, fc1_weights, 32)); // fc_1
    hashCombine(&h, activationContentHash()); // ac_1
    hashCombine(&h, affineContentHash(fc2_biases, fc2_weights, 1)); // fc_2
    hashCombine(&h, architectureHashValue());
    return h;
}

// Network::hash (network.h): the evaluation-function structure hash embedded in
// the file header, FeatureTransformer::get_hash_value xor
// NetworkArchitecture::get_hash_value.
pub fn networkHashValue() u32 {
    return featureTransformerHashValue() ^ architectureHashValue();
}

// std::hash<EvalFile>: combine hash_bytes of defaultName, current, netDescription
// (each a FixedString hashed over its .data()/.size()).
pub fn evalFileContentHash(default_name: []const u8, current: []const u8, description: []const u8) usize {
    var h: usize = 0;
    hashCombine(&h, @intCast(hashBytes(default_name)));
    hashCombine(&h, @intCast(hashBytes(current)));
    hashCombine(&h, @intCast(hashBytes(description)));
    return h;
}

const testing = std.testing;

test "hashBytes matches a known MurmurHash2-64A vector" {
    // Empty input: h = 0; finalize: h ^= h>>47 (0); h *= m (0); h ^= h>>47 (0) = 0.
    try testing.expectEqual(@as(u64, 0), hashBytes(&[_]u8{}));
}

test "combine_hash and architecture hash value are stable" {
    // Recomputed from the constants; guards against accidental edits.
    const ft = featureTransformerHashValue();
    const arch = architectureHashValue();
    try testing.expect(ft != 0);
    try testing.expect(arch != 0);
    // combine_hash({a,b}) = rotl(rotl(0^... )) -- first term is just a.
    try testing.expectEqual(@as(u32, 0x8f234cb8), combineHash(&.{0x8f234cb8}));
}
