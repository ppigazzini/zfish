const std = @import("std");

// One CorrectionBundle: the four correction StatsEntry<int16> fields, one [2] page
// per correctionHistory index (indexed by color).
pub const CorrectionBundle = struct {
    pawn: i16,
    minor: i16,
    nonpawn_white: i16,
    nonpawn_black: i16,
};

test {
    @import("std").testing.refAllDecls(@This());
}
