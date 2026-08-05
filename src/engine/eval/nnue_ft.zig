// Reach into the NNUE feature-transformer weight blob.
//
// Hold the typed accessors that hand back [*]const pointers to each weight region
// (psq i16, threat i8, and the two psqt i32 tables). Split out of
// nnue_accumulator.zig; pointer casts over the byte offsets, std-free. The offsets
// themselves are NOT computed here: nnue_dimensions owns the layout, and nnue_parse
// WRITES each region at those same declarations, so this reads back exactly where
// the parse wrote. The accumulator core imports this and aliases the four accessors.

const dims = @import("nnue_dimensions");

const nnue_align: usize = dims.cache_line_bytes;

// The threat weight rows hold FullThreats AND PP_3Wide concatenated -- upstream's single
// threatAndPpWeights array. A pp index is at or past the threat count and addresses the
// tail of this same region, so the threat weight accessor covers both feature sets.
const feature_transformer_weights_offset = dims.weights_off;
const feature_transformer_threat_weights_offset = dims.threat_weights_off;
const feature_transformer_psqt_weights_offset = dims.psqt_weights_off;
const feature_transformer_threat_psqt_weights_offset = dims.threat_psqt_weights_off;

/// Expose an opaque handle to the loaded feature-transformer weight blob. A raw
/// large-page byte arena whose layout is fixed by the .nnue file + SIMD access, so
/// the bytes stay raw -- but the *handle* is a distinct type, not a bare *anyopaque,
/// so the eval can't confuse it with the accumulator stack / cache handles. The
/// accessors below reinterpret it as bytes and hand back typed weight pointers.
pub const FeatureTransformer = opaque {};

// Carry the blob's 64-byte alignment in the returned pointer types: the arena is
// nnue_align'd (page_alloc contract) and every region offset above is rounded to
// nnue_align, so the casts hold. The SIMD kernels need the alignment in the TYPE --
// with an align(1) weight pointer, non-VEX SSE cannot fold a weight load into the
// consuming op's m128 operand (folding requires provable 16-byte alignment), which
// costs one extra movdqu per 16 weight bytes on the sse41 tier.
pub fn featureTransformerPsqWeights(feature_transformer: *const FeatureTransformer) [*]align(nnue_align) const i16 {
    const bytes: [*]const u8 = @ptrCast(feature_transformer);
    return @ptrCast(@alignCast(bytes + feature_transformer_weights_offset));
}

pub fn featureTransformerThreatWeights(feature_transformer: *const FeatureTransformer) [*]align(nnue_align) const i8 {
    const bytes: [*]const u8 = @ptrCast(feature_transformer);
    return @ptrCast(@alignCast(bytes + feature_transformer_threat_weights_offset));
}

pub fn featureTransformerPsqPsqtWeights(feature_transformer: *const FeatureTransformer) [*]align(nnue_align) const i32 {
    const bytes: [*]const u8 = @ptrCast(feature_transformer);
    return @ptrCast(@alignCast(bytes + feature_transformer_psqt_weights_offset));
}

pub fn featureTransformerThreatPsqtWeights(feature_transformer: *const FeatureTransformer) [*]align(nnue_align) const i32 {
    const bytes: [*]const u8 = @ptrCast(feature_transformer);
    return @ptrCast(@alignCast(bytes + feature_transformer_threat_psqt_weights_offset));
}

test {
    @import("std").testing.refAllDecls(@This());
}
