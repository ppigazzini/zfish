// NNUE feature-transformer weight-blob layout (M17.4e).
//
// The comptime byte-offset table into the loaded FeatureTransformer weight blob
// plus the typed accessors that hand back [*]const pointers to each weight region
// (psq i16, threat i8, and the two psqt i32 tables). Split out of
// nnue_accumulator.zig; pure comptime layout math + pointer casts, std-free, no
// module deps -- the dimension consts + roundUp are duplicated locally. The
// accumulator core imports this and aliases the four accessors.

const half_dimensions: usize = 1024;
const psqt_buckets: usize = 8;
const nnue_align: usize = 64;
const psq_feature_dimensions: usize = 22528;
const threat_dimensions: u32 = 60720;

fn roundUp(value: usize, alignment: usize) usize {
    return ((value + alignment - 1) / alignment) * alignment;
}

const feature_transformer_biases_bytes = half_dimensions * @sizeOf(i16);
const feature_transformer_psq_weights_bytes = half_dimensions * psq_feature_dimensions * @sizeOf(i16);
const feature_transformer_threat_weights_bytes = half_dimensions * @as(usize, threat_dimensions) * @sizeOf(i8);
const feature_transformer_psqt_weights_bytes = psq_feature_dimensions * psqt_buckets * @sizeOf(i32);
const feature_transformer_weights_offset = roundUp(feature_transformer_biases_bytes, nnue_align);
const feature_transformer_threat_weights_offset = roundUp(feature_transformer_weights_offset + feature_transformer_psq_weights_bytes, nnue_align);
const feature_transformer_psqt_weights_offset = roundUp(feature_transformer_threat_weights_offset + feature_transformer_threat_weights_bytes, nnue_align);
const feature_transformer_threat_psqt_weights_offset = roundUp(feature_transformer_psqt_weights_offset + feature_transformer_psqt_weights_bytes, nnue_align);

/// Opaque handle to the loaded feature-transformer weight blob (M18.4-B4). A raw
/// large-page byte arena whose layout is fixed by the .nnue file + SIMD access, so
/// the bytes stay raw -- but the *handle* is a distinct type, not a bare *anyopaque,
/// so the eval can't confuse it with the accumulator stack / cache handles. The
/// accessors below reinterpret it as bytes and hand back typed weight pointers.
pub const FeatureTransformer = opaque {};

pub fn featureTransformerPsqWeights(feature_transformer: *const FeatureTransformer) [*]const i16 {
    const bytes: [*]const u8 = @ptrCast(feature_transformer);
    return @ptrCast(@alignCast(bytes + feature_transformer_weights_offset));
}

pub fn featureTransformerThreatWeights(feature_transformer: *const FeatureTransformer) [*]const i8 {
    const bytes: [*]const u8 = @ptrCast(feature_transformer);
    return @ptrCast(bytes + feature_transformer_threat_weights_offset);
}

pub fn featureTransformerPsqPsqtWeights(feature_transformer: *const FeatureTransformer) [*]const i32 {
    const bytes: [*]const u8 = @ptrCast(feature_transformer);
    return @ptrCast(@alignCast(bytes + feature_transformer_psqt_weights_offset));
}

pub fn featureTransformerThreatPsqtWeights(feature_transformer: *const FeatureTransformer) [*]const i32 {
    const bytes: [*]const u8 = @ptrCast(feature_transformer);
    return @ptrCast(@alignCast(bytes + feature_transformer_threat_psqt_weights_offset));
}

test {
    @import("std").testing.refAllDecls(@This());
}
