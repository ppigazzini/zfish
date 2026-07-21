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
// Lane count for the single-@Vector row ops -- the refresh dual-store and the additive/split
// row helpers (accRows, applyAccumulatorDeltaDualStoreI16). Target-aware: 256 on avx512, 64
// everywhere else. A paired HW-counter check found 128 REGRESSES sse41 (+1.4% instr, +4.1%
// cycles): with only 16 xmm even 128 spills. aarch64 keeps 64, unmeasured. The hot combined
// apply uses its own register-array knob (apply_num_regs) instead. Distinct from the transform's
// width knob (nnue_acc_layout).
const is_avx512 = @import("builtin").cpu.arch == .x86_64 and
    @import("std").Target.x86.featureSetHas(@import("builtin").cpu.features, .avx512f);

const row_tile_width: usize = if (is_avx512) 256 else 64;
comptime {
    if (half_dimensions % row_tile_width != 0)
        @compileError("half_dimensions must be a multiple of row_tile_width");
}

/// Shape the combined-apply tile as upstream's SIMDTiling does: an ARRAY of `apply_num_regs`
/// SIMD registers, each `apply_reg_lanes` i16 wide, widening the threat i8 rows one register at a
/// time -- never materializing the whole widened tile at once. That per-register widen is what
/// lets the tile reach 512 (upstream's 2-tile shape over the 1024 row) on avx512: a single
/// @Vector(512,i16) needs 16 zmm live and a transient 16-zmm i16 result during the whole-tile
/// i8->i16 widen, which spills; widening one 32-lane register at a time keeps only the 16 acc
/// registers live plus a single transient. Non-avx512 keeps num_regs=1, so the kernel stays
/// byte-identical to the prior single-@Vector form (a [1]@Vector(64,i16) unrolls to the same
/// code). The `k` index MUST stay comptime (`inline for`) or the acc array spills to memory (D8).
const apply_reg_lanes: usize = if (is_avx512) 32 else 64;
const apply_num_regs: usize = if (is_avx512) 16 else 1;
const apply_tile_h: usize = apply_reg_lanes * apply_num_regs;
comptime {
    if (half_dimensions % apply_tile_h != 0)
        @compileError("half_dimensions must be a multiple of apply_tile_h");
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
    weights: [*]const WT,
) void {
    const V = row_tile_width;
    const Vi16 = @Vector(V, i16);
    var d: usize = 0;
    while (d < half_dimensions) : (d += V) {
        var acc: Vi16 = target.ptr[d..][0..V].*;
        for (rows) |index| {
            const wraw: @Vector(V, WT) = (weights + @as(usize, index) * half_dimensions)[d..][0..V].*;
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
    weights: [*]const i16,
) void {
    @memcpy(target, source);
    accRows(i16, false, target, removed, weights);
    accRows(i16, true, target, added, weights);
}

pub fn applyAccumulatorDeltaInPlaceI16(
    target: []i16,
    removed: []const u32,
    added: []const u32,
    weights: [*]const i16,
) void {
    accRows(i16, false, target, removed, weights);
    accRows(i16, true, target, added, weights);
}

pub fn applyAccumulatorDeltaI8(
    target: []i16,
    source: []const i16,
    removed: []const u32,
    added: []const u32,
    weights: [*]const i8,
) void {
    @memcpy(target, source);
    accRows(i8, false, target, removed, weights);
    accRows(i8, true, target, added, weights);
}

pub fn accumulateRowsI8(target: []i16, rows: []const u32, weights: [*]const i8) void {
    accRows(i8, true, target, rows, weights);
}

/// Apply the removed/added row lists to `cache` and write the result to BOTH `cache`
/// (the finny-table entry, updated in place) and `state` (the stack's refreshed copy)
/// in ONE tiled pass. Ports upstream's refresh, which stores the tiled accumulation
/// straight into the accumulator AND the cache entry -- so the cache-to-state copy is a
/// second register store, not a separate compiler_rt @memcpy of the whole 1024-wide row.
/// Bit-exact: the stored value is source -Σremoved +Σadded, the same as the prior
/// two-pass in-place delta followed by a copy (i16 +%/-% commute), and both targets get
/// exactly that value, so ReleaseSafe sees the identical run.
pub fn applyAccumulatorDeltaDualStoreI16(
    cache: []i16,
    state: []i16,
    removed: []const u32,
    added: []const u32,
    weights: [*]const i16,
) void {
    const V = row_tile_width;
    const Vi16 = @Vector(V, i16);
    var d: usize = 0;
    while (d < half_dimensions) : (d += V) {
        var acc: Vi16 = cache.ptr[d..][0..V].*;
        for (removed) |index| {
            const w: Vi16 = (weights + @as(usize, index) * half_dimensions)[d..][0..V].*;
            acc -%= w;
        }
        for (added) |index| {
            const w: Vi16 = (weights + @as(usize, index) * half_dimensions)[d..][0..V].*;
            acc +%= w;
        }
        cache.ptr[d..][0..V].* = acc;
        state.ptr[d..][0..V].* = acc;
    }
}

/// The psqt half of applyAccumulatorDeltaDualStoreI16: apply both column lists to the
/// single 8-bucket i32 vector and store it to both the cache entry and the stack state.
pub fn applyPsqtDeltaDualStore(
    cache: []i32,
    state: []i32,
    removed: []const u32,
    added: []const u32,
    weights: [*]const i32,
) void {
    const V = @Vector(psqt_buckets, i32);
    var acc: V = cache[0..psqt_buckets].*;
    for (removed) |index| {
        const w: V = (weights + @as(usize, index) * psqt_buckets)[0..psqt_buckets].*;
        acc -%= w;
    }
    for (added) |index| {
        const w: V = (weights + @as(usize, index) * psqt_buckets)[0..psqt_buckets].*;
        acc +%= w;
    }
    cache[0..psqt_buckets].* = acc;
    state[0..psqt_buckets].* = acc;
}

pub fn applyPsqtDelta(
    target: []i32,
    source: []const i32,
    removed: []const u32,
    added: []const u32,
    weights: [*]const i32,
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
    weights: [*]const i32,
) void {
    const V = @Vector(psqt_buckets, i32);
    var acc: V = target[0..psqt_buckets].*;
    for (removed) |index| {
        const w: V = (weights + @as(usize, index) * psqt_buckets)[0..psqt_buckets].*;
        acc -%= w;
    }
    for (added) |index| {
        const w: V = (weights + @as(usize, index) * psqt_buckets)[0..psqt_buckets].*;
        acc +%= w;
    }
    target[0..psqt_buckets].* = acc;
}

pub fn accumulatePsqtRows(target: []i32, rows: []const u32, weights: [*]const i32) void {
    const V = @Vector(psqt_buckets, i32);
    var acc: V = target[0..psqt_buckets].*;
    for (rows) |index| {
        const w: V = (weights + @as(usize, index) * psqt_buckets)[0..psqt_buckets].*;
        acc +%= w;
    }
    target[0..psqt_buckets].* = acc;
}

// Port (hand-vectorized) upstream Stockfish's `apply_combined` (nnue_accumulator.cpp):
// one combined accumulator (HalfKA + Threats), loaded per tile ONCE into a register array
// (`acc[apply_num_regs]`, upstream's SIMDTiling shape), with both feature sets' removed/added
// weight rows applied in-register (psq int16 rows via i16 add/sub, threat int8 rows widened to
// i16 one register at a time), then stored ONCE. Replaces the two separate load/store
// round-trips (one per feature) of the split-accumulator design.
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
    psq_weights: [*]const i16,
    thr_weights: [*]const i8,
) void {
    const L = apply_reg_lanes;
    const N = apply_num_regs;
    const RegI16 = @Vector(L, i16);
    const RegI8 = @Vector(L, i8);
    var t: usize = 0;
    while (t < half_dimensions) : (t += L * N) {
        // Hold the whole tile as N registers, mirroring upstream `vec_t acc[NumRegs]`. The k
        // index is comptime (`inline for`), so the array lives in registers across every column
        // loop (D8); the runtime `index` only picks the weight row's base.
        var acc: [N]RegI16 = undefined;
        inline for (0..N) |k| {
            acc[k] = source.ptr[t + k * L ..][0..L].*;
        }
        for (psq_removed) |index| {
            const base = @as(usize, index) * half_dimensions + t;
            inline for (0..N) |k| {
                const w: RegI16 = (psq_weights + base + k * L)[0..L].*;
                acc[k] -%= w;
            }
        }
        for (psq_added) |index| {
            const base = @as(usize, index) * half_dimensions + t;
            inline for (0..N) |k| {
                const w: RegI16 = (psq_weights + base + k * L)[0..L].*;
                acc[k] +%= w;
            }
        }
        for (thr_removed) |index| {
            const base = @as(usize, index) * half_dimensions + t;
            inline for (0..N) |k| {
                const wraw: RegI8 = (thr_weights + base + k * L)[0..L].*;
                acc[k] -%= @as(RegI16, wraw); // per-register i8 -> i16 widen, one vpmovsxbw
            }
        }
        for (thr_added) |index| {
            const base = @as(usize, index) * half_dimensions + t;
            inline for (0..N) |k| {
                const wraw: RegI8 = (thr_weights + base + k * L)[0..L].*;
                acc[k] +%= @as(RegI16, wraw);
            }
        }
        inline for (0..N) |k| {
            target.ptr[t + k * L ..][0..L].* = acc[k];
        }
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
    psq_weights: [*]const i32,
    thr_weights: [*]const i32,
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
        const w: V = (psq_weights + @as(usize, index) * psqt_buckets)[0..psqt_buckets].*;
        acc -%= w;
    }
    for (psq_added) |index| {
        const w: V = (psq_weights + @as(usize, index) * psqt_buckets)[0..psqt_buckets].*;
        acc +%= w;
    }
    for (thr_removed) |index| {
        const w: V = (thr_weights + @as(usize, index) * psqt_buckets)[0..psqt_buckets].*;
        acc -%= w;
    }
    for (thr_added) |index| {
        const w: V = (thr_weights + @as(usize, index) * psqt_buckets)[0..psqt_buckets].*;
        acc +%= w;
    }
    target[0..psqt_buckets].* = acc;
}

test {
    @import("std").testing.refAllDecls(@This());
}
