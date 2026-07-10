const std = @import("std");

// One CorrectionBundle (src/history.h): the four correction StatsEntry<int16>
// fields, one [2] page per correctionHistory index (indexed by color). Extracted to
// a std-only leaf (M18.7) so the shared-history SharedHistories record can name it
// from a leaf that worker_histories imports, without dragging in the
// search_types -> worker_histories edge (which would cycle). search_types re-exports
// this as its canonical CorrectionBundle, so every existing reference is unchanged.
pub const CorrectionBundle = struct {
    pawn: i16,
    minor: i16,
    nonpawn_white: i16,
    nonpawn_black: i16,
};
