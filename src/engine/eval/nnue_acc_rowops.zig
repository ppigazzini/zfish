// Implement the NNUE accumulator SIMD row ops.
//
// The vectorized feature-transformer weight-row add/sub kernels split out of
// nnue_accumulator.zig. Fully self-contained: pure @Vector math over the FT
// weight rows (plus SSSE3's pmaddubsw for the paired widen), depending only on the
// two network dimensions (duplicated as tiny consts). No *anyopaque, no position_snapshot / nnue_feature, so no cycle. The
// accumulator core imports this and aliases the kernels. Bit-exact: the wrapping
// vector +%/-% is the same element-wise op as the scalar loop it replaces, and
// mirrors upstream's `_mm*_add/sub_epi16` (2's-complement wrap) (bench 2497913).

const std = @import("std");

const half_dimensions: usize = 1024;

/// Set the lane count for the FT weight-row add/sub tile. Sweep it as the only variable: on sse41
/// 64 beats 32 by +3.4%/+4.7%; on avx512 256 beats 128 (measured -3.6% instr / -2.5% cycles at
/// vnni512, perf_counters 10-round paired) -- it drops the 1024-wide row from 8 tiles to 4,
/// matching upstream SIMDTiling's 2-tile shape and cutting the inner-loop setup. Independent of
/// nnue_acc_layout's transform_vec_width.
// Lane count for the combined accumulator row apply. Target-aware, upstream's
// BestRegisterCount shape (8 native registers per tile at every x86 tier): 256 on
// avx512 (16 zmm hold the 4-register accumulator live across all four column loops),
// 128 on plain avx2 (8 ymm -- upstream's
// TileHeight; halves the per-tile row-list walks that a 64-lane tile pays twice),
// 64 on sse. A paired HW-counter check found 128 REGRESSES sse41 (+1.4% instr,
// +4.1% cycles): with only 16 xmm even 128 spills. aarch64 keeps 64, unmeasured.
//
// 256 is HALF upstream's avx512 TileHeight, which its SIMDTiling arithmetic puts at 512
// (NumRegs 16 -> two tiles of the 1024-wide row); zfish matches upstream at avx2 and sse
// and diverges only here. 512 was swept at avx512icl and is a real -3.4% instruction win
// that does NOT land: it needs 16 zmm (not 32) and does NOT spill, but removing the spare
// registers stops LLVM unrolling the row loop by 2, and the resulting body is +51% larger
// in applyCombined -- an instruction win paid for in instruction FETCH. Re-measure the
// front end, not just the instruction axis, before revisiting.
// Distinct from the transform's width knob (nnue_acc_layout).
const row_tile_width: usize = blk: {
    const b = @import("builtin");
    if (b.target.cpu.arch == .x86_64) {
        if (@import("std").Target.x86.featureSetHas(b.target.cpu.features, .avx512f)) break :blk 256;
        if (@import("std").Target.x86.featureSetHas(b.target.cpu.features, .avx2)) break :blk 128;
    }
    break :blk 64;
};
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

/// Apply one feature list to ONE accumulator tile -- upstream's `apply_psq_features` and
/// `apply_threat_features`, which since SFNNv18 differ only in the list and the sign: every
/// weight row is int8, widened to i16 on load the way upstream's `apply_feature_single`
/// (`vec_convert_8_16`) does. `IT` is the list's element type -- u16 for the K32Q2 indices
/// (upstream d96c183f), u32 for the threat and pawn-pair ones.
inline fn tileRows(
    comptime IT: type,
    comptime add: bool,
    acc: *@Vector(row_tile_width, i16),
    rows: []const IT,
    weights: [*]align(64) const i8,
    tile_off: usize,
) void {
    if (!add and apple_tuned) {
        // Sum the rows, then take the sum out once: the same wrapping i16 value, but an add
        // recurrence, which LLVM 22 recombines correctly. See apple_tuned.
        var sum: @Vector(row_tile_width, i16) = @splat(0);
        for (rows) |index| tileRow(IT, true, &sum, index, weights, tile_off);
        acc.* -%= sum;
        return;
    }
    for (rows) |index| tileRow(IT, add, acc, index, weights, tile_off);
}

/// Mark an Apple CPU model, which Zig's `.baseline` picks on aarch64-macos (apple_m1). LLVM 22
/// (Zig 0.17) unrolls a loop subtracting widened i8 rows into four zero-started partial
/// accumulators for these models only, then recombines them with the wrong signs: the tile
/// comes out near the NEGATED source once a list holds 4+ rows. LLVM 21 (Zig 0.16) and every
/// other aarch64 model (generic, cortex, neoverse, oryon, ampere) compile it correctly, and
/// every add is unaffected. Since SFNNv18 the K32Q2 rows are int8 too, so the refresh's
/// removed list takes this path as well. Linux aarch64 built with an apple model
/// reproduces it under qemu-aarch64; drop this once that repro passes on the pinned Zig.
const apple_tuned = blk: {
    const b = @import("builtin");
    break :blk b.target.cpu.arch == .aarch64 and std.mem.startsWith(u8, b.target.cpu.model.name, "apple_");
};

/// Add or subtract ONE weight row into the tile -- the body of upstream's
/// `apply_feature_single<sign>`.
inline fn tileRow(
    comptime IT: type,
    comptime add: bool,
    acc: *@Vector(row_tile_width, i16),
    index: IT,
    weights: [*]align(64) const i8,
    tile_off: usize,
) void {
    const V = row_tile_width;
    const Vi16 = @Vector(V, i16);
    const wraw: @Vector(V, i8) = loadVec(i8, V, 64, weights, @as(usize, index) * half_dimensions + tile_off);
    const w: Vi16 = wraw; // i8 -> i16 widen
    acc.* = if (add) acc.* +% w else acc.* -% w;
}

/// Apply a K32Q2 list of KNOWN length one or two -- upstream's
/// `apply_psq_features<sign, Incremental = true>` (8bc5caa2). A single ply's piece diff
/// names at most two changed K32Q2 squares per direction and always at least one (the
/// moved piece leaves `from` and arrives at `to`; a capture or a promotion adds the second),
/// so the counted loop's trip test is knowledge the caller already has. Peeling the first
/// row hands it over: one unconditional apply, then one predicated one.
///
/// The precondition is upstream's own `assert(list.size() == 1 || list.size() == 2)`, and
/// it holds for the same reason -- a null move pushes no accumulator state on either side,
/// so nothing reaches here with an empty list. In ReleaseFast the assert is gone and
/// `rows[0]` is unguarded, exactly as upstream's unguarded `list[0]` is; ReleaseSafe and
/// the test builds are what check it.
inline fn tileRowsIncremental(
    comptime IT: type,
    comptime add: bool,
    acc: *@Vector(row_tile_width, i16),
    rows: []const IT,
    weights: [*]align(64) const i8,
    tile_off: usize,
) void {
    std.debug.assert(rows.len == 1 or rows.len == 2);
    tileRow(IT, add, acc, rows[0], weights, tile_off);
    if (rows.len > 1) tileRow(IT, add, acc, rows[1], weights, tile_off);
}

// ---- paired widening (upstream e08dfa804) ------------------------------------------

/// Widen two int8 rows with one byte interleave and one `pmaddubsw` against a vector of
/// ones, instead of one sign extension per row -- upstream's USE_PAIRED_WIDENING_ADD (simd.h),
/// taken at the one tier where it is less work here: SSSE3 without SSE4.1.
///
/// Upstream enables it on every x86 tier from SSSE3 up. Ported at every width -- 128, 256 and
/// 512-bit pairs, with the load-time 8-byte-block permutation the wider unpacks need -- it
/// benched 1559611 everywhere and measured, instructions per node against the one-row kernels
/// (perf_counters, 10 rounds, bench 16 1 13): native 5125 -> 5335 (+4.1%), avx2 7344 -> 7449
/// (+1.4%), sse41 11157 -> 12091 (+8.4%), ssse3 13200 -> 12393 (-6.1%). Where SSE4.1 exists
/// the one-row widen is a `pmovsxbw` straight from memory and an add, which a pair can at
/// best match, and the odd row out of each list costs an unpack and a shift where
/// `pmovsxbw` was one op. Without SSE4.1 the one-row widen already IS an unpack and a shift,
/// and pairing halves it.
const paired_widening = blk: {
    const b = @import("builtin");
    const has = std.Target.x86.featureSetHas;
    break :blk b.target.cpu.arch == .x86_64 and has(b.target.cpu.features, .ssse3) and
        !has(b.target.cpu.features, .sse4_1);
};

const PairVi8 = @Vector(16, i8);
const PairVi16 = @Vector(16, i16);

/// Interleave the low (`high = false`) or high eight bytes of `a` and `b` -- `punpck{l,h}bw`.
const unpack_lo_mask: @Vector(16, i32) = .{ 0, ~@as(i32, 0), 1, ~@as(i32, 1), 2, ~@as(i32, 2), 3, ~@as(i32, 3), 4, ~@as(i32, 4), 5, ~@as(i32, 5), 6, ~@as(i32, 6), 7, ~@as(i32, 7) };
const unpack_hi_mask: @Vector(16, i32) = .{ 8, ~@as(i32, 8), 9, ~@as(i32, 9), 10, ~@as(i32, 10), 11, ~@as(i32, 11), 12, ~@as(i32, 12), 13, ~@as(i32, 13), 14, ~@as(i32, 14), 15, ~@as(i32, 15) };
const concat_mask: @Vector(16, i32) = .{ 0, 1, 2, 3, 4, 5, 6, 7, ~@as(i32, 0), ~@as(i32, 1), ~@as(i32, 2), ~@as(i32, 3), ~@as(i32, 4), ~@as(i32, 5), ~@as(i32, 6), ~@as(i32, 7) };

const pmaddubsw128 = struct {
    extern fn @"llvm.x86.ssse3.pmadd.ub.sw.128"(@Vector(16, i8), @Vector(16, i8)) callconv(.{ .x86_64_sysv = .{} }) @Vector(8, i16);
}.@"llvm.x86.ssse3.pmadd.ub.sw.128";

/// Sum two 16-byte int8 chunks into sixteen int16 lanes -- the body of upstream's
/// `apply_feature_pair`. `pmaddubsw` against ones adds each interleaved byte pair and cannot
/// saturate (|a + b| <= 256), and at 128 bits the two unpacks land in natural lane order, so
/// the rows need no load-time permutation.
inline fn pairWiden(a: PairVi8, b: PairVi8) PairVi16 {
    const ones: PairVi8 = @splat(1);
    const lo = pmaddubsw128(ones, @shuffle(i8, a, b, unpack_lo_mask));
    const hi = pmaddubsw128(ones, @shuffle(i8, a, b, unpack_hi_mask));
    return @shuffle(i16, lo, hi, concat_mask);
}

const Row = [*]align(64) const i8;

/// Hold the int8 rows one apply adds or removes, as row pointers -- upstream's WeightRows. Rows
/// of every feature set with the same sign go in one list, so nearly every row has a partner.
const WeightRows = struct {
    /// Fit a K32Q2 list (32 rows) plus a threat and pawn-pair list (256), as upstream's
    /// AllWeightRows sizes itself from the two MaxActiveDimensions.
    rows: [32 + 256]Row,
    len: usize,

    /// Start an empty list without touching the row array. `.{}` with an undefined default
    /// still lowers to a 2312-byte memset per list per call (measured: compiler_rt.fastMemset
    /// in applyCombinedDelta), which costs more than every pair saves.
    inline fn empty() WeightRows {
        var r: WeightRows = undefined;
        r.len = 0;
        return r;
    }

    inline fn appendPsq(self: *WeightRows, list: []const u16, weights: [*]align(64) const i8) void {
        for (list) |index| {
            self.rows[self.len] = @alignCast(weights + @as(usize, index) * half_dimensions);
            self.len += 1;
        }
    }

    inline fn appendThreat(self: *WeightRows, list: []const u32, weights: [*]align(64) const i8) void {
        for (list) |index| {
            self.rows[self.len] = @alignCast(weights + @as(usize, index) * half_dimensions);
            self.len += 1;
        }
    }

    /// Apply every row to one tile, two at a time -- upstream's WeightRows::apply.
    inline fn apply(self: *const WeightRows, comptime add: bool, acc: *@Vector(row_tile_width, i16), tile_off: usize) void {
        const chunks = row_tile_width / 16;
        var i: usize = 0;
        while (i + 1 < self.len) : (i += 2) {
            var parts: [chunks]PairVi16 = undefined;
            inline for (0..chunks) |c| {
                const a = loadVec(i8, 16, 16, self.rows[i], tile_off + c * 16);
                const b = loadVec(i8, 16, 16, self.rows[i + 1], tile_off + c * 16);
                parts[c] = pairWiden(a, b);
            }
            const inc: @Vector(row_tile_width, i16) = @bitCast(parts);
            acc.* = if (add) acc.* +% inc else acc.* -% inc;
        }
        if (i < self.len) {
            // The odd row out widens on its own, which is upstream's unpack-and-shift: without
            // SSE4.1 that is how the sign extension lowers.
            tileRow(usize, add, acc, 0, self.rows[i], tile_off);
        }
    }
};

/// Refresh in ONE tiled pass -- upstream update_accumulator_refresh_cache's loop shape:
/// load the finny-cache tile, apply the K32Q2 removed/added rows, store the psq-only
/// tile back to `cache`, then KEEP ADDING the active Threat rows in the same registers
/// and store the combined tile to `state`. Replaces the dual-store pass plus a separate
/// accumulate pass, which reloaded and rewrote the whole 2 KB row it had just
/// stored. Per element the wrapping-add order (psq removed, psq added, threat active)
/// and both stored values are unchanged, so cache and state hold byte-identical results
/// and ReleaseSafe sees the identical run.
pub fn applyRefreshFused(
    cache: []i16,
    state: []i16,
    removed: []const u16,
    added: []const u16,
    active: []const u32,
    psq_weights: [*]align(64) const i8,
    thr_weights: [*]align(64) const i8,
) void {
    const V = row_tile_width;
    const Vi16 = @Vector(V, i16);
    if (comptime paired_widening) {
        var entry_removed: WeightRows = .empty();
        var entry_added: WeightRows = .empty();
        var active_rows: WeightRows = .empty();
        entry_removed.appendPsq(removed, psq_weights);
        entry_added.appendPsq(added, psq_weights);
        active_rows.appendThreat(active, thr_weights);
        var d: usize = 0;
        while (d < half_dimensions) : (d += V) {
            var acc: Vi16 = cache.ptr[d..][0..V].*;
            entry_removed.apply(false, &acc, d);
            entry_added.apply(true, &acc, d);
            cache.ptr[d..][0..V].* = acc;
            active_rows.apply(true, &acc, d);
            state.ptr[d..][0..V].* = acc;
        }
        return;
    }
    var d: usize = 0;
    while (d < half_dimensions) : (d += V) {
        var acc: Vi16 = cache.ptr[d..][0..V].*;
        tileRows(u16, false, &acc, removed, psq_weights, d);
        tileRows(u16, true, &acc, added, psq_weights, d);
        cache.ptr[d..][0..V].* = acc;
        tileRows(u32, true, &acc, active, thr_weights, d);
        state.ptr[d..][0..V].* = acc;
    }
}

/// Take a same-half king move incrementally -- upstream's update_accumulator_hybrid
/// (nnue_accumulator.cpp). A king move rebuckets every K32Q2 index, but the threat and
/// pawn-pair orientation depends only on which HALF of the board the king stands on, so a
/// king move that stays on its half keeps that whole accumulation. Only the K32Q2 half
/// has to change buckets, and both buckets are reachable from the refresh cache:
///
///   target = computed - <old-bucket K32Q2> + <new-bucket K32Q2> + <this ply's thr/pp delta>
///
/// One register per tile carries the destination-entry refresh, the bucket swap and the
/// threat delta, so the 2 KB row is loaded once. `new_entry` is refreshed in place
/// mid-pass (it is the bucket the next ply will read), exactly as the refresh kernel
/// stores its own entry back.
///
/// Order matters for the entry store, not for the value: every step is a wrapping i16
/// add/sub, which commutes -- but `new_entry` must be stored BEFORE `computed` is folded
/// in, or the cache entry keeps the accumulated position instead of the bucket.
pub fn applyHybridDelta(
    target: []i16,
    computed: []const i16,
    new_entry: []i16,
    old_entry: []const i16,
    new_removed: []const u16,
    new_added: []const u16,
    old_removed: []const u16,
    old_added: []const u16,
    thr_removed: []const u32,
    thr_added: []const u32,
    psq_weights: [*]align(64) const i8,
    thr_weights: [*]align(64) const i8,
) void {
    const V = row_tile_width;
    const Vi16 = @Vector(V, i16);
    if (comptime paired_widening) {
        var entry_removed: WeightRows = .empty();
        var entry_added: WeightRows = .empty();
        entry_removed.appendPsq(new_removed, psq_weights);
        entry_added.appendPsq(new_added, psq_weights);
        // The old entry's removed rows go back in, its added rows come out.
        var rows_removed: WeightRows = .empty();
        var rows_added: WeightRows = .empty();
        rows_added.appendPsq(old_removed, psq_weights);
        rows_added.appendThreat(thr_added, thr_weights);
        rows_removed.appendPsq(old_added, psq_weights);
        rows_removed.appendThreat(thr_removed, thr_weights);
        var d: usize = 0;
        while (d < half_dimensions) : (d += V) {
            var acc: Vi16 = new_entry.ptr[d..][0..V].*;
            entry_removed.apply(false, &acc, d);
            entry_added.apply(true, &acc, d);
            new_entry.ptr[d..][0..V].* = acc;
            acc +%= @as(Vi16, computed.ptr[d..][0..V].*);
            acc -%= @as(Vi16, old_entry.ptr[d..][0..V].*);
            rows_removed.apply(false, &acc, d);
            rows_added.apply(true, &acc, d);
            target.ptr[d..][0..V].* = acc;
        }
        return;
    }
    var d: usize = 0;
    while (d < half_dimensions) : (d += V) {
        // Refresh the DESTINATION bucket from its cache entry.
        var acc: Vi16 = new_entry.ptr[d..][0..V].*;
        tileRows(u16, false, &acc, new_removed, psq_weights, d);
        tileRows(u16, true, &acc, new_added, psq_weights, d);
        new_entry.ptr[d..][0..V].* = acc;

        // Fold in the computed accumulator -- which brings (most of) the threat and pawn-pair
        // weights along -- then take back the psq accumulation it carries for the OLD bucket.
        acc +%= @as(Vi16, computed.ptr[d..][0..V].*);
        acc -%= @as(Vi16, old_entry.ptr[d..][0..V].*);

        // The old entry is a cache state, not the pre-move position, so undo its own diff:
        // its removed rows are re-added and its added rows taken back out.
        tileRows(u16, true, &acc, old_removed, psq_weights, d);
        tileRows(u16, false, &acc, old_added, psq_weights, d);

        // This ply's threat/pawn-pair change, at the new king square.
        tileRows(u32, false, &acc, thr_removed, thr_weights, d);
        tileRows(u32, true, &acc, thr_added, thr_weights, d);
        target.ptr[d..][0..V].* = acc;
    }
}

/// Port (hand-vectorized) upstream Stockfish's `apply_combined` (nnue_accumulator.cpp):
/// one combined accumulator (K32Q2 + Threats), loaded per tile ONCE into a register,
/// with both feature sets' removed/added weight rows applied in-register (every row int8,
/// widened to i16), then stored ONCE. Replaces the two
/// separate load/store round-trips (one per feature) of the split-accumulator design.
/// Integer +%/-% commute under 2's-complement i16 wrap (upstream `_mm*_add/sub_epi16`), so
/// the final tile value equals
/// source + Σpsq_added − Σpsq_removed + Σthr_added − Σthr_removed regardless of order:
/// bit-exact with the prior two-accumulator path (signature 2497913).
pub fn applyCombinedDelta(
    target: []i16,
    source: []const i16,
    psq_removed: []const u16,
    psq_added: []const u16,
    thr_removed: []const u32,
    thr_added: []const u32,
    psq_weights: [*]align(64) const i8,
    thr_weights: [*]align(64) const i8,
) void {
    const V = row_tile_width;
    const Vi16 = @Vector(V, i16);
    if (comptime paired_widening) {
        var rows_removed: WeightRows = .empty();
        var rows_added: WeightRows = .empty();
        rows_removed.appendPsq(psq_removed, psq_weights);
        rows_removed.appendThreat(thr_removed, thr_weights);
        rows_added.appendPsq(psq_added, psq_weights);
        rows_added.appendThreat(thr_added, thr_weights);
        var d: usize = 0;
        while (d < half_dimensions) : (d += V) {
            var acc: Vi16 = source.ptr[d..][0..V].*;
            rows_removed.apply(false, &acc, d);
            rows_added.apply(true, &acc, d);
            target.ptr[d..][0..V].* = acc;
        }
        return;
    }
    var d: usize = 0;
    while (d < half_dimensions) : (d += V) {
        var acc: Vi16 = source.ptr[d..][0..V].*;
        tileRowsIncremental(u16, false, &acc, psq_removed, psq_weights, d);
        tileRowsIncremental(u16, true, &acc, psq_added, psq_weights, d);
        tileRows(u32, false, &acc, thr_removed, thr_weights, d);
        tileRows(u32, true, &acc, thr_added, thr_weights, d);
        target.ptr[d..][0..V].* = acc;
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
