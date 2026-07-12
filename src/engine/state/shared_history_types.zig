const std = @import("std");
const correction_bundle = @import("correction_bundle");

const CorrectionBundle = correction_bundle.CorrectionBundle;

// The SharedHistories layout, reached through the Worker's shared_history pointer.
// correctionHistory and pawnHistory are each a DynStats { size_t size; T* data } (an
// 8-byte data pointer), followed by the two index masks. pawn page = [16][64] int16
// (1024); correction page = [2]CorrectionBundle. shared_history.zig re-exports this as
// its canonical SharedHistories.
pub const SharedHistories = struct {
    corr_size: usize,
    corr_data: [*][2]CorrectionBundle,
    pawn_size: usize,
    pawn_data: [*]i16,
    size_minus1: usize,
    pawn_hist_size_minus1: usize,
};

test {
    @import("std").testing.refAllDecls(@This());
}
