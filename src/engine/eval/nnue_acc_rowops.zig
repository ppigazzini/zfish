// Implement the NNUE accumulator SIMD row ops.
//
// The vectorized feature-transformer weight-row add/sub kernels split out of
// nnue_accumulator.zig. Fully self-contained: pure @Vector math over the FT
// weight rows, depending only on the two network dimensions (duplicated as tiny
// consts). No *anyopaque, no position_snapshot / nnue_feature, so no cycle. The
// accumulator core imports this and aliases the kernels. Bit-exact: the wrapping
// vector +%/-% is the same element-wise op as the scalar loop it replaces, and
// mirrors upstream's `_mm*_add/sub_epi16` (2's-complement wrap) (bench 2792255).

const half_dimensions: usize = 1024;
const psqt_buckets: usize = 8;

/// Set the lane count for the FT weight-row add/sub tile. Sweep it as the only variable: on sse41
/// 64 beats 32 by +3.4%/+4.7%; on avx512 256 beats 128 (measured -3.6% instr / -2.5% cycles at
/// vnni512, perf_counters 10-round paired) -- it drops the 1024-wide row from 8 tiles to 4,
/// matching upstream SIMDTiling's 2-tile shape and cutting the inner-loop setup. Independent of
/// nnue_acc_layout's transform_vec_width.
// Lane count for the combined accumulator row apply. Target-aware: 256 on avx512 (16 zmm hold the
// 4-register accumulator live across all four column loops; 512 would need 32 zmm and spill), but
// 64 everywhere else. A paired HW-counter check found 128 REGRESSES sse41 (+1.4% instr, +4.1%
// cycles): with only 16 xmm even 128 spills. aarch64 keeps 64, unmeasured. Distinct from the
// transform's width knob (nnue_acc_layout).
const row_tile_width: usize = if (@import("builtin").cpu.arch == .x86_64 and
    @import("std").Target.x86.featureSetHas(@import("builtin").cpu.features, .avx512f)) 256 else 64;
comptime {
    if (half_dimensions % row_tile_width != 0)
        @compileError("half_dimensions must be a multiple of row_tile_width");
}

/// Load one V-lane vector from `p + off` (elements), asserting alignment `A` (bytes) on the
/// load itself. Slicing a many-pointer at a runtime offset degrades the load to the element
/// alignment in Zig's type system, and the backend folds a load into a non-VEX SSE op's m128
/// operand only when >=16-byte alignment is provable -- an align(1) load costs a separate
/// movdqu per chunk on the sse41 tier. Every caller's offset is a multiple of A by layout
/// (row stride x element size), which ReleaseSafe's @alignCast check pins.
inline fn loadVec(comptime T: type, comptime V: usize, comptime A: usize, p: [*]const T, off: usize) @Vector(V, T) {
    const ap: *align(A) const [V]T = @ptrCast(@alignCast(p + off));
    return ap.*;
}

/// Apply a whole row list to the accumulator, upstream's `apply_combined` way: tile the
/// accumulator, hold the tile in a register, and walk the rows INSIDE. The rows are the inner
/// loop, so the accumulator is loaded and stored once per tile rather than once per row --
/// which is what a row-outer loop costs, since each row streams all half_dimensions of it
/// through memory.
///
/// Order per element is unchanged, and i16 wrap-around (`+%`/`-%`, matching upstream's
/// `_mm*_add/sub_epi16`) is associative regardless, so this is bit-identical to applying
/// the rows one at a time.
inline fn accRows(
    comptime WT: type,
    comptime add: bool,
    target: []i16,
    rows: []const u32,
    weights: [*]align(64) const WT,
) void {
    const V = row_tile_width;
    const Vi16 = @Vector(V, i16);
    var d: usize = 0;
    while (d < half_dimensions) : (d += V) {
        var acc: Vi16 = target.ptr[d..][0..V].*;
        for (rows) |index| {
            const wraw: @Vector(V, WT) = loadVec(WT, V, 64, weights, @as(usize, index) * half_dimensions + d);
            const w: Vi16 = wraw; // i8 -> i16 widen; i16 identity
            acc = if (add) acc +% w else acc -% w;
        }
        target.ptr[d..][0..V].* = acc;
    }
}

pub fn applyAccumulatorDeltaI16(
    target: []i16,
    source: []const i16,
    removed: []const u32,
    added: []const u32,
    weights: [*]align(64) const i16,
) void {
    @memcpy(target, source);
    accRows(i16, false, target, removed, weights);
    accRows(i16, true, target, added, weights);
}

pub fn applyAccumulatorDeltaInPlaceI16(
    target: []i16,
    removed: []const u32,
    added: []const u32,
    weights: [*]align(64) const i16,
) void {
    accRows(i16, false, target, removed, weights);
    accRows(i16, true, target, added, weights);
}

pub fn applyAccumulatorDeltaI8(
    target: []i16,
    source: []const i16,
    removed: []const u32,
    added: []const u32,
    weights: [*]align(64) const i8,
) void {
    @memcpy(target, source);
    accRows(i8, false, target, removed, weights);
    accRows(i8, true, target, added, weights);
}

/// Refresh in ONE tiled pass -- upstream update_accumulator_refresh_cache's loop shape:
/// load the finny-cache tile, apply the HalfKA removed/added rows, store the psq-only
/// tile back to `cache`, then KEEP ADDING the active Threat rows in the same registers
/// and store the combined tile to `state`. Replaces the dual-store pass plus a separate
/// accumulateRowsI8 pass, which reloaded and rewrote the whole 2 KB row it had just
/// stored. Per element the wrapping-add order (psq removed, psq added, threat active)
/// and both stored values are unchanged, so cache and state hold byte-identical results
/// and ReleaseSafe sees the identical run.
pub fn applyRefreshFusedI16(
    cache: []i16,
    state: []i16,
    removed: []const u32,
    added: []const u32,
    active: []const u32,
    psq_weights: [*]align(64) const i16,
    thr_weights: [*]align(64) const i8,
) void {
    const V = row_tile_width;
    const Vi16 = @Vector(V, i16);
    var d: usize = 0;
    while (d < half_dimensions) : (d += V) {
        var acc: Vi16 = cache.ptr[d..][0..V].*;
        for (removed) |index| {
            const w: Vi16 = loadVec(i16, V, 64, psq_weights, @as(usize, index) * half_dimensions + d);
            acc -%= w;
        }
        for (added) |index| {
            const w: Vi16 = loadVec(i16, V, 64, psq_weights, @as(usize, index) * half_dimensions + d);
            acc +%= w;
        }
        cache.ptr[d..][0..V].* = acc;
        for (active) |index| {
            const wraw: @Vector(V, i8) = loadVec(i8, V, 64, thr_weights, @as(usize, index) * half_dimensions + d);
            acc +%= @as(Vi16, wraw); // i8 -> i16 widen
        }
        state.ptr[d..][0..V].* = acc;
    }
}

/// The psqt half of applyRefreshFusedI16: one 8-bucket i32 vector; `cache` receives the
/// psq-only value, `state` receives psq plus the active threat psqt rows.
pub fn applyRefreshFusedPsqt(
    cache: []i32,
    state: []i32,
    removed: []const u32,
    added: []const u32,
    active: []const u32,
    psq_weights: [*]align(64) const i32,
    thr_weights: [*]align(64) const i32,
) void {
    const V = @Vector(psqt_buckets, i32);
    var acc: V = cache[0..psqt_buckets].*;
    for (removed) |index| {
        const w: V = loadVec(i32, psqt_buckets, 32, psq_weights, @as(usize, index) * psqt_buckets);
        acc -%= w;
    }
    for (added) |index| {
        const w: V = loadVec(i32, psqt_buckets, 32, psq_weights, @as(usize, index) * psqt_buckets);
        acc +%= w;
    }
    cache[0..psqt_buckets].* = acc;
    for (active) |index| {
        const w: V = loadVec(i32, psqt_buckets, 32, thr_weights, @as(usize, index) * psqt_buckets);
        acc +%= w;
    }
    state[0..psqt_buckets].* = acc;
}

pub fn applyPsqtDelta(
    target: []i32,
    source: []const i32,
    removed: []const u32,
    added: []const u32,
    weights: [*]align(64) const i32,
) void {
    @memcpy(target, source);

    for (removed) |index| {
        const row_offset = @as(usize, index) * psqt_buckets;
        var bucket: usize = 0;
        while (bucket < psqt_buckets) : (bucket += 1) {
            target[bucket] -%= weights[row_offset + bucket];
        }
    }

    for (added) |index| {
        const row_offset = @as(usize, index) * psqt_buckets;
        var bucket: usize = 0;
        while (bucket < psqt_buckets) : (bucket += 1) {
            target[bucket] +%= weights[row_offset + bucket];
        }
    }
}

// Keep the tile in ONE register across all rows, as the fused combined path below does: the
// 8-bucket i32 row is a single vector, and the scalar 8-step inner loop these replaced stays
// scalar forever -- the toolchain does not auto-vectorize integer loops. Per-row op order is
// unchanged (removed then added), so ReleaseSafe sees identical intermediates.
pub fn applyPsqtDeltaInPlace(
    target: []i32,
    removed: []const u32,
    added: []const u32,
    weights: [*]align(64) const i32,
) void {
    const V = @Vector(psqt_buckets, i32);
    var acc: V = target[0..psqt_buckets].*;
    for (removed) |index| {
        const w: V = loadVec(i32, psqt_buckets, 32, weights, @as(usize, index) * psqt_buckets);
        acc -%= w;
    }
    for (added) |index| {
        const w: V = loadVec(i32, psqt_buckets, 32, weights, @as(usize, index) * psqt_buckets);
        acc +%= w;
    }
    target[0..psqt_buckets].* = acc;
}

// Port (hand-vectorized) upstream Stockfish's `apply_combined` (nnue_accumulator.cpp):
// one combined accumulator (HalfKA + Threats), loaded per tile ONCE into a register,
// with both feature sets' removed/added weight rows applied in-register (psq int16 rows
// via i16 add/sub, threat int8 rows widened to i16), then stored ONCE. Replaces the two
// separate load/store round-trips (one per feature) of the split-accumulator design.
// Integer +%/-% commute under 2's-complement i16 wrap (upstream `_mm*_add/sub_epi16`), so
// the final tile value equals
// source + Σpsq_added − Σpsq_removed + Σthr_added − Σthr_removed regardless of order:
// bit-exact with the prior two-accumulator path (signature 2792255).
pub fn applyCombinedDelta(
    target: []i16,
    source: []const i16,
    psq_removed: []const u32,
    psq_added: []const u32,
    thr_removed: []const u32,
    thr_added: []const u32,
    psq_weights: [*]align(64) const i16,
    thr_weights: [*]align(64) const i8,
) void {
    const V = row_tile_width;
    const Vi16 = @Vector(V, i16);
    var d: usize = 0;
    while (d < half_dimensions) : (d += V) {
        var acc: Vi16 = source.ptr[d..][0..V].*;
        for (psq_removed) |index| {
            const w: Vi16 = loadVec(i16, V, 64, psq_weights, @as(usize, index) * half_dimensions + d);
            acc -%= w;
        }
        for (psq_added) |index| {
            const w: Vi16 = loadVec(i16, V, 64, psq_weights, @as(usize, index) * half_dimensions + d);
            acc +%= w;
        }
        for (thr_removed) |index| {
            const wraw: @Vector(V, i8) = loadVec(i8, V, 64, thr_weights, @as(usize, index) * half_dimensions + d);
            acc -%= @as(Vi16, wraw); // i8 -> i16 widen
        }
        for (thr_added) |index| {
            const wraw: @Vector(V, i8) = loadVec(i8, V, 64, thr_weights, @as(usize, index) * half_dimensions + d);
            acc +%= @as(Vi16, wraw);
        }
        target.ptr[d..][0..V].* = acc;
    }
}

// Mirror applyCombinedDelta for psqt: one combined psqtAccumulation, both feature
// sets applied (psq + threat psqt weights, both i32). Scalar -- PSQTBuckets is tiny.
pub fn applyCombinedPsqtDelta(
    target: []i32,
    source: []const i32,
    psq_removed: []const u32,
    psq_added: []const u32,
    thr_removed: []const u32,
    thr_added: []const u32,
    psq_weights: [*]align(64) const i32,
    thr_weights: [*]align(64) const i32,
) void {
    // Fuse as upstream's apply_combined does for the psqt tile (nnue_accumulator.cpp:248-268):
    // load the 8-bucket row into ONE register, apply both feature sets' removed/added columns
    // in-register, store once. PSQTBuckets x i32 is a single 256-bit vector, so the update has
    // no memory round-trip -- where a memcpy plus two in-memory passes wrote the row three
    // times, and the auto-vectorizer leaves such integer loops scalar. The operation ORDER
    // (psq removed, psq added, thr removed, thr added) is exactly the two-pass order it
    // replaces, so every intermediate value matches and ReleaseSafe sees the identical run.
    const V = @Vector(psqt_buckets, i32);
    var acc: V = source[0..psqt_buckets].*;
    for (psq_removed) |index| {
        const w: V = loadVec(i32, psqt_buckets, 32, psq_weights, @as(usize, index) * psqt_buckets);
        acc -%= w;
    }
    for (psq_added) |index| {
        const w: V = loadVec(i32, psqt_buckets, 32, psq_weights, @as(usize, index) * psqt_buckets);
        acc +%= w;
    }
    for (thr_removed) |index| {
        const w: V = loadVec(i32, psqt_buckets, 32, thr_weights, @as(usize, index) * psqt_buckets);
        acc -%= w;
    }
    for (thr_added) |index| {
        const w: V = loadVec(i32, psqt_buckets, 32, thr_weights, @as(usize, index) * psqt_buckets);
        acc +%= w;
    }
    target[0..psqt_buckets].* = acc;
}

test {
    @import("std").testing.refAllDecls(@This());
}
