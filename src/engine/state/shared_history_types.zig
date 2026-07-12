const std = @import("std");
const correction_bundle = @import("correction_bundle");

const CorrectionBundle = correction_bundle.CorrectionBundle;

// Memory mirror of SharedHistories (src/history.h), reached through the Worker
// mirror's shared_history pointer. correctionHistory and pawnHistory are each a
// DynStats { size_t size; T* data } (the LargePagePtr is a unique_ptr with a
// stateless deleter, so just an 8-byte pointer), followed by the two index masks.
// pawn page = [16][64] int16 (1024); correction page = [2]CorrectionBundle.
//
// Extracted to a leaf over correction_bundle (M18.7) so worker_histories can name
// this type for its `shared_history` field without importing shared_history.zig --
// which imports worker_histories, so the reverse would cycle. shared_history.zig
// re-exports this as its canonical SharedHistories, keeping the management + accessor
// code unchanged.
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
