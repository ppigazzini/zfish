// The affine kernels' one shared weight-chunk load, in its own leaf so both nnue_affine.zig and
// the nnue_affine_vnni.zig tier can reach it without either importing the other.

/// Load one 16/32/64-byte weight chunk asserting alignment `A` on the load itself: a
/// runtime-offset slice of a many-pointer degrades to align(1), and non-VEX SSE folds a
/// load into pmaddubsw's m128 operand only when >=16-byte alignment is provable. The
/// scrambled layout keeps every chunk offset a multiple of its width, and the weight
/// tables are 64-aligned allocations, so the assert holds (ReleaseSafe checks it).
pub inline fn loadW(comptime N: usize, comptime A: usize, p: [*]const i8, off: usize) @Vector(N, i8) {
    const ap: *align(A) const [N]i8 = @ptrCast(@alignCast(p + off));
    return ap.*;
}
