// Sort the leading run of qualifying moves in two 512-bit registers, as upstream's
// MoveSorter does (movepick.cpp:66, gated on USE_AVX512). Values and moves are held in
// SEPARATE lanes so an insertion is one masked expand each; write() reassembles the
// 8-byte SortEntries with a permute across the register pair. Up to `max` moves are
// sorted with no data-dependent branching, where the scalar loop
// (movepick.partialInsertionSort) shifts elements one at a time.
//
// The order this produces must be the scalar order EXACTLY -- a difference of one swap
// changes the move loop and therefore the search tree. See the cross-check test at the
// bottom, run against a reference scalar sort over thousands of random inputs.
//
// Gated on AVX512F + AVX512DQ, not AVX512F alone: `_kadd_mask16`'s underlying
// `llvm.x86.avx512.kadd.w` needs AVX512DQ specifically (verified by compiling a probe
// with clang and inspecting the emitted LLVM IR -- `-mavx512f` alone rejects it). Every
// x86-64-vnni512-or-above tier this repo defines already sets both.

const std = @import("std");
const builtin = @import("builtin");
const movepick_score = @import("movepick_score.zig");

const SortEntry = movepick_score.SortEntry;

pub const use_avx512_sort = builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512dq);

pub const max: usize = 16;

const V16i32 = @Vector(16, i32);
const V16mask = @Vector(16, bool);

// LLVM intrinsic names/argument orders verified empirically: compiled each upstream
// intrinsic call with clang -O2 -mavx512f -mavx512dq -S -emit-llvm and read the
// resulting `declare`/`call` lines, rather than assuming a signature from the C
// intrinsic name. In particular `_mm512_mask_expand_epi32(src, k, a)` lowers to
// `@llvm.x86.avx512.mask.expand.v16i32(a, src, mask)` -- note src and a SWAP position.
extern fn @"llvm.x86.avx512.mask.expand.v16i32"(a: V16i32, src: V16i32, mask: V16mask) V16i32;
extern fn @"llvm.x86.avx512.kadd.w"(a: V16mask, b: V16mask) V16mask;
extern fn @"llvm.x86.avx512.vpermi2var.d.512"(a: V16i32, idx: V16i32, b: V16i32) V16i32;

inline fn entryLanes(e: SortEntry) [2]i32 {
    // raw_move+reserved (offset 0) is the "move" lane, value (offset 4) the "value"
    // lane -- SortEntry is extern specifically so this bitcast is well-defined.
    return @bitCast(e);
}

pub const MoveSorter = struct {
    sorted_values: V16i32,
    sorted_moves: V16i32,

    pub fn init(first: SortEntry) MoveSorter {
        const lanes = entryLanes(first);
        const moves: V16i32 = @splat(lanes[0]);
        const values: V16i32 = @splat(lanes[1]);
        // Every lane but the first sorts below any real move (upstream's
        // `_mm512_mask_set1_epi32(sorted_values, ~1, INT32_MIN)`).
        var keep_first: [16]bool = @splat(false);
        keep_first[0] = true;
        const keep_first_v: V16mask = keep_first;
        const min_v: V16i32 = @splat(std.math.minInt(i32));
        return .{
            .sorted_values = @select(i32, keep_first_v, values, min_v),
            .sorted_moves = moves,
        };
    }

    pub fn insert(self: *MoveSorter, m: SortEntry) void {
        const lanes = entryLanes(m);
        const move: V16i32 = @splat(lanes[0]);
        const value: V16i32 = @splat(lanes[1]);

        // Mask of every element except the insertion point: sorted_values is
        // maintained in descending order with unused tail lanes at INT32_MIN, so
        // "sorted_values[i] < value" is always a contiguous suffix; kadd (== -1,
        // i.e. subtract 1 from that suffix-as-integer) flips it to "every bit except
        // the insertion point".
        const cmplt: V16mask = self.sorted_values < value;
        const all_ones: V16mask = @splat(true);
        const expand = @"llvm.x86.avx512.kadd.w"(cmplt, all_ones);

        self.sorted_values = @"llvm.x86.avx512.mask.expand.v16i32"(self.sorted_values, value, expand);
        self.sorted_moves = @"llvm.x86.avx512.mask.expand.v16i32"(self.sorted_moves, move, expand);
    }

    // Reassemble up to `count` (<= 16) SortEntries from the two parallel lane
    // registers and write them to entries[0..count). Upstream reassembles with a
    // single masked 64-bit vector store per half; this does the same permute (the
    // part that must match bit-for-bit) but writes the result with a plain bounded
    // scalar loop instead of a masked store intrinsic -- fewer instructions saved,
    // zero correctness difference, and one fewer intrinsic signature to get exactly
    // right.
    pub fn write(self: *const MoveSorter, entries: [*]SortEntry, count: usize) void {
        const lo: V16i32 = .{ 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23 };
        const hi: V16i32 = .{ 8, 24, 9, 25, 10, 26, 11, 27, 12, 28, 13, 29, 14, 30, 15, 31 };
        var offset: usize = 0;
        while (offset < max and offset < count) : (offset += 8) {
            const idx = if (offset == 0) lo else hi;
            const ext = @"llvm.x86.avx512.vpermi2var.d.512"(self.sorted_moves, idx, self.sorted_values);
            const packed_pairs: [8]u64 = @bitCast(ext);
            const store_count = @min(count - offset, 8);
            var j: usize = 0;
            while (j < store_count) : (j += 1) {
                entries[offset + j] = @bitCast(packed_pairs[j]);
            }
        }
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

// A pure-scalar reference, independent of movepick.partialInsertionSort's own
// (possibly vectorized) implementation, so this test cannot pass by both sides
// sharing a bug.
fn referenceSort(entries: []SortEntry, limit: i32) void {
    if (entries.len == 0) return;
    var sorted_end: usize = 0;
    var scan: usize = 1;
    while (scan < entries.len) : (scan += 1) {
        if (entries[scan].value >= limit) {
            const current = entries[scan];
            sorted_end += 1;
            entries[scan] = entries[sorted_end];
            var insert_at = sorted_end;
            while (insert_at != 0 and entries[insert_at - 1].value < current.value) : (insert_at -= 1) {
                entries[insert_at] = entries[insert_at - 1];
            }
            entries[insert_at] = current;
        }
    }
}

fn vectorSort(entries: []SortEntry, limit: i32) void {
    if (entries.len == 0) return;
    var sorted_end: usize = 0;
    var scan: usize = 1;
    var sorter = MoveSorter.init(entries[0]);
    while (scan < entries.len) : (scan += 1) {
        if (entries[scan].value >= limit) {
            if (sorted_end + 1 >= max) break;
            sorter.insert(entries[scan]);
            sorted_end += 1;
            entries[scan] = entries[sorted_end];
        }
    }
    sorter.write(entries.ptr, sorted_end + 1);
    while (scan < entries.len) : (scan += 1) {
        if (entries[scan].value >= limit) {
            const current = entries[scan];
            sorted_end += 1;
            entries[scan] = entries[sorted_end];
            var insert_at = sorted_end;
            while (insert_at != 0 and entries[insert_at - 1].value < current.value) : (insert_at -= 1) {
                entries[insert_at] = entries[insert_at - 1];
            }
            entries[insert_at] = current;
        }
    }
}

test "vectorSort matches referenceSort, random inputs up to and beyond the 16-move sorter cap" {
    if (comptime !use_avx512_sort) return error.SkipZigTest;
    var rng = std.Random.DefaultPrng.init(0x5EED_C0FF_EE00_1234);
    const random = rng.random();
    var trial: usize = 0;
    while (trial < 20000) : (trial += 1) {
        const count = 1 + random.uintLessThan(usize, 40); // exercise below, at, and above max=16
        const limit_kind = random.uintLessThan(u8, 3);
        const limit: i32 = switch (limit_kind) {
            0 => std.math.minInt(i32), // every entry qualifies
            1 => 0,
            else => random.intRangeAtMost(i32, -50, 50),
        };

        var a: [64]SortEntry = undefined;
        var b: [64]SortEntry = undefined;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const raw_move: u16 = @intCast(random.uintLessThan(u32, 4096));
            // Bias values into a small range so ties (equal value, order-sensitive) are
            // exercised often, not just as a rare edge case.
            const value: i32 = random.intRangeAtMost(i32, -20, 20);
            a[i] = .{ .raw_move = raw_move, .reserved = 0, .value = value };
            b[i] = a[i];
        }

        referenceSort(a[0..count], limit);
        vectorSort(b[0..count], limit);

        for (0..count) |idx| {
            testing.expectEqual(a[idx].raw_move, b[idx].raw_move) catch |err| {
                std.debug.print("trial {d} count {d} limit {d} mismatch at {d}\n", .{ trial, count, limit, idx });
                return err;
            };
            try testing.expectEqual(a[idx].value, b[idx].value);
        }
    }
}

test {
    // Gate refAllDecls too, not just the cross-check test above: refAllDecls forces
    // analysis of every declaration in this file regardless of runtime reachability,
    // which would still try to codegen the AVX-512 intrinsic calls inside MoveSorter's methods on
    // a target that can't lower them -- a comptime guard on the call site alone (the
    // test above) does not stop that.
    if (comptime use_avx512_sort) std.testing.refAllDecls(@This());
}
