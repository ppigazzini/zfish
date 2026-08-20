// Parse one PairsData's header out of a Syzygy table file (SF `set_sizes`).
//
// Split from decode.zig on the 500-line lint, along the boundary that file already
// states: this is the LOAD-time half, which runs once per table and can therefore
// afford `@setRuntimeSafety(true)` and graceful `error.CorruptTable` rejection, while
// decode.zig keeps the PROBE-time half that runs inside the search. The split is the
// same one docs/05-tablebases.md draws between what the header can be made to prove
// and what only the payload decides.
//
// Import decode.zig for the byte readers and the TBFlag bits; the dependency runs one
// way, so decode.zig must never import this file back.

const std = @import("std");
const probe = @import("probe.zig");
const decode = @import("decode.zig");

const PairsData = probe.PairsData;

const rdU16 = decode.rdU16;
const rdU32 = decode.rdU32;
const rdSym = decode.rdSym;
const flag_single_value = decode.flag_single_value;

// Port SF `set_sizes`: parse the header for one PairsData starting at `buf[pos]`, allocate base64[]
// and symlen[], set the file pointers, and advance `pos` past the btree. group_len/group_idx must
// already be filled (setGroups). Return an error only on OOM.
pub fn setSizes(gpa: std.mem.Allocator, d: *PairsData, buf: []const u8, pos: *usize) !void {
    // Keep runtime safety on over this header parse even in ReleaseFast. Every byte read here is
    // at a file-derived offset, the file is untrusted, and this runs once per table at load --
    // never on the probe path. The explicit `error.CorruptTable` returns below are the graceful
    // rejection; this is the backstop under them.
    @setRuntimeSafety(true);
    var p = pos.*;
    if (p >= buf.len) return error.CorruptTable;
    d.flags = buf[p];
    p += 1;

    if (d.flags & flag_single_value != 0) {
        d.blocks_num = 0;
        d.block_length_size = 0;
        d.span = 0;
        d.sparse_index_size = 0;
        if (p >= buf.len) return error.CorruptTable;
        d.min_sym_len = buf[p]; // the single stored value
        p += 1;
        pos.* = p;
        return;
    }

    // Nine fixed header bytes follow the flags byte before any variable-length region:
    // sizeof_block, span, padding, blocks_num (4), max_sym_len, min_sym_len.
    if (buf.len - p < 9) return error.CorruptTable;

    // Compute tbSize as group_idx at the group_len[] terminator index.
    var term: usize = 0;
    while (term < probe.tb_pieces and d.group_len[term] != 0) term += 1;
    const tb_size: u64 = d.group_idx[term];

    // Both are stored as log2 and used as SHIFT WIDTHS, so a raw file byte reaches the shift
    // amount directly: anything at 64 or beyond does not fit the u6 it is cast to. Found by
    // src/platform/syzygy/fuzz_targets.zig, which panicked here on the first fuzzed header.
    // Before the parse raised runtime safety this cast was silent in ReleaseFast, and
    // sizeof_block then carried garbage into the data-region size below.
    if (buf[p] >= 64 or buf[p + 1] >= 64) return error.CorruptTable;
    d.sizeof_block = @as(usize, 1) << @intCast(buf[p]);
    p += 1;
    d.span = @as(usize, 1) << @intCast(buf[p]);
    p += 1;
    // Saturate the round-up: span is bounded above but still large enough that `tb_size + span`
    // can wrap u64, and a wrapped size would understate the sparse index rather than reject it.
    d.sparse_index_size = (tb_size +| d.span -| 1) / d.span;
    const padding: u8 = buf[p];
    p += 1;
    d.blocks_num = rdU32(buf[p..]);
    p += 4;
    // blocks_num is a full u32 straight out of the file, so this sum can overflow u32.
    d.block_length_size = std.math.add(u32, d.blocks_num, padding) catch
        return error.CorruptTable;
    d.max_sym_len = buf[p];
    p += 1;
    d.min_sym_len = buf[p];
    p += 1;

    // Both symbol lengths are raw file bytes. Reject an inverted, oversized or zero pair before
    // the arithmetic below: max < min underflows the u8 subtraction; a length at 64 or beyond
    // drives the right-pad shift negative; and min == 0 makes the k == 0 shift width exactly 64,
    // which does not fit the u6 the shift takes. None is representable, so a corrupt table must
    // be refused here rather than trapping (ReleaseSafe) or shifting by garbage (ReleaseFast).
    // min == 0 stays legal on the SingleValue branch above, where min_sym_len is a stored value
    // rather than a code length.
    if (d.min_sym_len == 0 or d.min_sym_len > d.max_sym_len or d.max_sym_len >= 64)
        return error.CorruptTable;

    const base64_size: usize = @as(usize, d.max_sym_len - d.min_sym_len) + 1;

    // lowest_sym is a Sym[base64_size]: the loop below reads index base64_size - 1 at most, and
    // so does decompressPairs (`len` cannot exceed base64_size - 1, see there). Carve it with
    // that bound instead of taking a bare `.ptr` that outlives every length the file states.
    d.lowest_sym = take(buf, &p, base64_size * 2) orelse return error.CorruptTable;

    d.base64 = try gpa.alloc(u64, base64_size);
    // Release it on every later rejection. The shipped caller passes the registry ARENA, which
    // frees on reset regardless -- but a headless caller (the unit tests, the fuzz target) passes
    // a checking allocator, and without this each refused table leaks its base64. That is what
    // caught it: std.testing.allocator reported the leak the moment a corrupt-table test existed.
    errdefer {
        gpa.free(d.base64);
        d.base64 = &.{};
    }

    // Build canonical Huffman: base64[i] >= base64[i+1] (see SF). base64[last] starts at 0.
    d.base64[base64_size - 1] = 0;
    var i = base64_size - 1;
    // Wrap, do not trap. Upstream's recurrence is `uint64_t`, whose overflow is DEFINED to wrap,
    // and the two symbol reads are raw file bytes: on a corrupt table the subtrahend routinely
    // exceeds the sum, which a plain `-` reports as an integer overflow. The fuzz target found
    // exactly that. Wrapping keeps zfish bit-identical to upstream on every valid table and
    // yields a garbage-but-defined base64 on an invalid one, which the btree validation and the
    // probe-time bounds below then contain.
    while (i > 0) {
        i -= 1;
        d.base64[i] = (d.base64[i + 1] +%
            @as(u64, rdSym(d.lowest_sym[i * 2 ..])) -%
            @as(u64, rdSym(d.lowest_sym[(i + 1) * 2 ..]))) / 2;
        // Refuse a non-canonical code. A canonical Huffman table satisfies
        // base64[i] * 2 >= base64[i + 1] at every step; upstream asserted it and 5fd94536 turned
        // the assert into a rejection, because on an untrusted file the assert is compiled out
        // and the decoder then walks an alphabet its own length scan cannot describe. Double
        // with wrapping, as upstream's u64 does.
        if (d.base64[i] *% 2 < d.base64[i + 1]) return error.CorruptTable;
    }
    // Right-pad to 64 bits. base64_size <= max_sym_len - min_sym_len + 1, max_sym_len < 64 and
    // min_sym_len >= 1, so 64 - k - min_sym_len stays in 1..63 and the shift width is in range.
    for (d.base64, 0..) |*value, k| {
        const shift: u6 = @intCast(64 - k - d.min_sym_len);
        value.* <<= shift;
    }

    if (buf.len - p < 2) return error.CorruptTable;
    const symlen_size: usize = rdU16(buf[p..]);
    p += 2;
    // Carve the btree with a bound: symlen_size is a file-stated u16, so it can promise far more
    // entries than the file carries. @alignCast is a no-op here (LR is [3]u8, alignment 1) and
    // must stay that way -- a wider LR would need the offset aligned, not just cast.
    comptime std.debug.assert(@alignOf(probe.LR) == 1);
    const btree_bytes = take(buf, &p, symlen_size * @sizeOf(probe.LR)) orelse
        return error.CorruptTable;
    d.btree = @as([*]const probe.LR, @ptrCast(btree_bytes.ptr))[0..symlen_size];

    // Validate the whole tree BEFORE walking it. Both child fields are 12 bits of the file, so a
    // corrupt entry can name a symbol past the tree -- and setSymLen writes d.symlen[child],
    // which ReleaseFast would not bounds-check. Validating once here, at load, makes the walk
    // in-bounds by construction and leaves the probe path free of the check. A leaf's `left` is
    // the stored VALUE, not a symbol, so range-check only non-leaves.
    for (d.btree) |entry| {
        if (entry.right() == 0xFFF) continue; // leaf
        if (entry.left() >= symlen_size or entry.right() >= symlen_size)
            return error.CorruptTable;
    }

    d.symlen = try gpa.alloc(u8, symlen_size);
    errdefer {
        gpa.free(d.symlen);
        d.symlen = &.{};
    }
    @memset(d.symlen, 0);
    // Three colours, not two: GREY marks a symbol still on the DFS path, which is what makes a
    // cycle detectable at all. With two states a symbol is marked before its subtree is walked,
    // so a cycle reads as "already computed" and the table is accepted with symlen[] entries
    // left at zero.
    const colour = try gpa.alloc(probe.SymColour, symlen_size);
    defer gpa.free(colour);
    @memset(colour, .white);
    var cyclic = false;
    var sym: usize = 0;
    while (sym < symlen_size) : (sym += 1)
        if (colour[sym] == .white) {
            d.symlen[sym] = probe.setSymLen(d, @intCast(sym), colour, &cyclic);
        };
    if (cyclic) return error.CorruptTable;

    try buildDecodeTables(gpa, d, base64_size, symlen_size);
    errdefer {
        gpa.free(@constCast(d.len_tab));
        d.len_tab = &.{};
    }

    p += symlen_size & 1;
    pos.* = p;
}

// Fill the tables the decode loop reads per symbol, and prove the alphabet the table declares.
//
// Three of the values the loop computed per symbol depend only on the symbol's LENGTH, of which
// a table has at most 63: the right-pad shift, the lowest symbol of that length folded with the
// base subtraction, and the real bit length the consumed word is shifted by. One entry each
// turns five arithmetic operations and an unaligned read out of the mapping into three loads.
//
// The fold is an IDENTITY, not an approximation, and it holds on every input rather than only on
// a well-formed one. base64[len] is right-padded by exactly `shift`, so its low `shift` bits are
// zero, and the scan only stops where buf64 >= base64[len] -- so
//
//     (buf64 - base64[len]) >> shift  ==  (buf64 >> shift) - (base64[len] >> shift)
//
// with no borrow to lose. Truncating that difference to 16 bits and adding lowest_sym is the same
// modular sum whichever order the terms are taken in, so the decoder's arithmetic is unchanged.
//
// `len_tab` answers the length SCAN, which is the single most expensive thing in the reader --
// measured at 13.6% of a whole probing search on this tree, a data-dependent loop no predictor
// learns. A code no longer than the index width owns a whole number of buckets of the word's top
// bits, because base64[] is right-padded to 64 bits: the span runs from its own base to one below
// the smallest base ahead of it, and both ends land on a bucket boundary while the length fits the
// index. So a byte per bucket answers exactly what the scan searched for. A bucket no such length
// covers holds only words longer than the index width, so it names the first index such a word can
// occupy and the scan resumes there. The entry is never above the true length either way, which is
// what lets the scan below it stand unchanged -- no sentinel, no branch.
//
// The alphabet proof replaces a bound the decoder used to carry per symbol. For each length the
// scan can reach, the widest word reaching it is one below the smallest base ahead of it, and that
// pins the largest symbol the length can name. A table naming one outside symlen[]'s domain is
// refused here, once per table opened, rather than tested once per symbol decoded. It is computed
// in u64 WITHOUT truncation, so it bounds a corrupt table too -- which is the whole point of
// moving it off the probe path.
fn buildDecodeTables(gpa: std.mem.Allocator, d: *PairsData, base64_size: usize, symlen_size: usize) !void {
    @setRuntimeSafety(true);

    // Per-length values. base64_size is at most 63 and the shift is in 1..63, both by the bounds
    // setSizes has already enforced on min_sym_len and max_sym_len.
    for (0..base64_size) |len| {
        const shift: u6 = @intCast(64 - len - d.min_sym_len);
        d.shift_tab[len] = shift;
        d.real_len_tab[len] = @intCast(len + d.min_sym_len);
        d.off_tab[len] = rdSym(d.lowest_sym[len * 2 ..]) -%
            @as(u16, @truncate(d.base64[len] >> shift));
    }

    // Cap the index at 12 bits. Uncapped it wants 2^63 entries; capped, the table stays 1 <<
    // max_sym_len bytes for a small alphabet and 4 KiB at most, and the buckets the stream reaches
    // are the same either way -- so the cap costs cache lines, not answers.
    const bits: u6 = @intCast(@min(d.max_sym_len, 12));
    const tab_shift: u6 = @intCast(64 - @as(u32, bits));
    // The first index a code longer than the table's width can occupy. Clamped into base64[]:
    // when every length fits the index the value would run one past the last entry, and it is
    // then never read, because no bucket is left uncovered.
    const escape: u8 = if (d.min_sym_len > bits)
        0
    else
        @intCast(@min(@as(usize, bits) + 1 - d.min_sym_len, base64_size - 1));

    const tab = try gpa.alloc(u8, @as(usize, 1) << bits);
    errdefer gpa.free(tab);
    @memset(tab, escape);

    // Walk the lengths once, carrying the smallest base AHEAD of the current one. The scan takes
    // the FIRST base a word clears, so that running minimum -- not base64[len - 1] -- is what
    // bounds a length's reachable span; a non-canonical table need not be descending, and this
    // form answers for one without assuming it is.
    var min_prev: u64 = std.math.maxInt(u64);
    for (0..base64_size) |len| {
        const reachable = len == 0 or (min_prev != 0 and d.base64[len] <= min_prev - 1);
        if (reachable) {
            const widest: u64 = if (len == 0) std.math.maxInt(u64) else min_prev - 1;

            // The proof: the largest symbol this length can name must index symlen[].
            const span = (widest - d.base64[len]) >> d.shift_tab[len];
            if (span + rdSym(d.lowest_sym[len * 2 ..]) >= symlen_size) return error.CorruptTable;

            // The buckets, for a length the index is wide enough to hold. Both ends are
            // bucket-aligned: this base is right-padded past the index width, and `widest` is one
            // below a base of a SHORTER length, which is padded further still.
            if (len + d.min_sym_len <= bits) {
                var bucket = d.base64[len] >> tab_shift;
                const last = widest >> tab_shift;
                while (bucket <= last) : (bucket += 1) tab[@intCast(bucket)] = @intCast(len);
            }
        }
        min_prev = @min(min_prev, d.base64[len]);
    }

    d.len_tab = tab;
    d.len_tab_shift = tab_shift;
}

// Carve `n` bytes out of `buf` at `pos.*`, advancing it, or null if the file is too short.
// Every file-backed region the decoder later walks goes through here, so a truncated or
// over-promising table is refused at load instead of read past the end at probe time.
fn take(buf: []const u8, pos: *usize, n: usize) ?[]const u8 {
    if (pos.* > buf.len or buf.len - pos.* < n) return null;
    const out = buf[pos.*..][0..n];
    pos.* += n;
    return out;
}

test "setSizes refuses an inverted, oversized or zero symbol-length pair" {
    const a = std.testing.allocator;
    // [flags][sizeof_block log][span log][padding][blocks_num u32][max_sym_len][min_sym_len]
    var buf = [_]u8{ 0, 6, 6, 0, 1, 0, 0, 0, 3, 9 };

    // max < min underflows the u8 subtraction that sizes base64.
    var d = PairsData{};
    var pos: usize = 0;
    try std.testing.expectError(error.CorruptTable, setSizes(a, &d, &buf, &pos));

    // A length at 64 or beyond drives the right-pad shift negative.
    buf[8] = 70;
    buf[9] = 64;
    d = PairsData{};
    pos = 0;
    try std.testing.expectError(error.CorruptTable, setSizes(a, &d, &buf, &pos));

    // min == 0 makes the k == 0 right-pad shift exactly 64, which does not fit the u6 it is
    // cast to -- an illegal cast in ReleaseSafe, a garbage shift in ReleaseFast.
    buf[8] = 9;
    buf[9] = 0;
    d = PairsData{};
    pos = 0;
    try std.testing.expectError(error.CorruptTable, setSizes(a, &d, &buf, &pos));
}

test "setSizes refuses out-of-range block/span shift widths" {
    const a = std.testing.allocator;
    // [flags][sizeof_block log][span log][padding][blocks_num u32][max_sym_len][min_sym_len]
    // Both log fields are raw file bytes used as SHIFT WIDTHS, so 64 and beyond does not fit
    // the u6 they are cast to.
    var d = probe.PairsData{};
    var pos: usize = 0;
    var buf = [_]u8{ 0, 64, 6, 0, 1, 0, 0, 0, 9, 1 };
    try std.testing.expectError(error.CorruptTable, setSizes(a, &d, &buf, &pos));

    buf[1] = 6;
    buf[2] = 255;
    d = probe.PairsData{};
    pos = 0;
    try std.testing.expectError(error.CorruptTable, setSizes(a, &d, &buf, &pos));
}

test "setSizes refuses a blocks_num + padding that overflows u32" {
    const a = std.testing.allocator;
    var buf = [_]u8{ 0, 6, 6, 0, 0, 0, 0, 0, 9, 1 };
    buf[3] = 1; // padding
    std.mem.writeInt(u32, buf[4..8], 0xFFFF_FFFF, .little); // blocks_num
    var d = probe.PairsData{};
    var pos: usize = 0;
    try std.testing.expectError(error.CorruptTable, setSizes(a, &d, &buf, &pos));
}

test "setSizes refuses a header that outruns the file" {
    const a = std.testing.allocator;
    // Truncated before the nine fixed header bytes are all present.
    var short = [_]u8{ 0, 6, 6, 0, 1, 0, 0 };
    var d = PairsData{};
    var pos: usize = 0;
    try std.testing.expectError(error.CorruptTable, setSizes(a, &d, &short, &pos));

    // An empty buffer cannot even yield the flags byte.
    d = PairsData{};
    pos = 0;
    try std.testing.expectError(error.CorruptTable, setSizes(a, &d, &.{}, &pos));

    // A well-formed header whose lowest_sym region the file does not carry. min=1, max=8 asks
    // for base64_size == 8 symbols == 16 bytes, and only a few follow.
    var stub = [_]u8{ 0, 6, 6, 0, 1, 0, 0, 0, 8, 1, 0, 0, 0, 0 };
    d = PairsData{};
    pos = 0;
    try std.testing.expectError(error.CorruptTable, setSizes(a, &d, &stub, &pos));
}

test "setSizes refuses a btree entry naming a symbol past the tree" {
    const a = std.testing.allocator;
    // Header: flags=0, sizeof_block=2^6, span=2^6, padding=0, blocks_num=1, max=1, min=1.
    // base64_size == 1, so 2 bytes of lowest_sym follow, then a u16 symlen_size, then the btree.
    var buf: [64]u8 = @splat(0);
    buf[0] = 0; // flags
    buf[1] = 6; // sizeof_block log
    buf[2] = 6; // span log
    buf[3] = 0; // padding
    std.mem.writeInt(u32, buf[4..8], 1, .little); // blocks_num
    buf[8] = 1; // max_sym_len
    buf[9] = 1; // min_sym_len
    // lowest_sym[0] at 10..12, symlen_size at 12..14, btree from 14.
    std.mem.writeInt(u16, buf[12..14], 2, .little); // two symbols
    // Symbol 0: a non-leaf naming children 9 and 9 -- both past the two-entry tree. Encoding
    // mirrors probe.zig's `pair`: lr[0]=l&0xFF, lr[1]=(l>>8)|((r&0xF)<<4), lr[2]=r>>4.
    buf[14] = 9;
    buf[15] = 0x90;
    buf[16] = 0;
    // Symbol 1: a leaf (right == 0xFFF), which must stay accepted.
    buf[17] = 0;
    buf[18] = 0xF0;
    buf[19] = 0xFF;

    var d = PairsData{};
    var pos: usize = 0;
    try std.testing.expectError(error.CorruptTable, setSizes(a, &d, &buf, &pos));
}
