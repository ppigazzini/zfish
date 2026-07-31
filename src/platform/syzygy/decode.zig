//! Parse Syzygy files and RE-PAIR-decompress them. Port Stockfish's
//! `set_sizes` faithfully (parse one PairsData's header out of the mmapped file) and `decompress_pairs`
//! (given a value index, walk the SparseIndex/blockLength and decode the canonical-Huffman
//! symbol via the btree). Read each `number<T,LE/BE>` as std.mem.readInt (all zfish targets
//! are little-endian, so LittleEndian reads are native, BigEndian reads byte-swap).
//!
//! Treat these as the decoder half (WIP): do_probe_table (position->index) + probe_wdl + wiring land in
//! part 2, where the whole chain is gated bit-exact vs the oracle (`tb-wdl`). Note that only the SingleValue
//! path of decompress_pairs is independently testable here; the rest is validated end-to-end.
//! Walk bounds-checked slices, not raw pointer walks: a table file is untrusted input, and every
//! offset here comes out of it. setSizes carves each file-backed region with a bound and refuses a
//! table that cannot keep its own size promises; decompressPairs then only has to check what the
//! header could not pin (the block and symbol the payload decodes to). See docs/05-tablebases.md.

const std = @import("std");
const probe = @import("probe.zig");
const PairsData = probe.PairsData;
const Sym = probe.Sym;

// Define the SF TBFlag bits.
pub const flag_stm: u8 = 1;
pub const flag_mapped: u8 = 2;
pub const flag_win_plies: u8 = 4;
pub const flag_loss_plies: u8 = 8;
pub const flag_wide: u8 = 16;
pub const flag_single_value: u8 = 128;

// Read unaligned little-/big-endian values off a file byte SLICE (SF `number<T, LE/BE>`). Take a
// slice rather than a `[*]`: the width is then checked against a length the caller established,
// which is the whole point of carving the file into bounded regions at load.
inline fn rdU16(p: []const u8) u16 {
    return std.mem.readInt(u16, p[0..2], .little);
}
inline fn rdU32(p: []const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}
inline fn rdSym(p: []const u8) Sym {
    return std.mem.readInt(u16, p[0..2], .little);
}
inline fn rdU64be(p: []const u8) u64 {
    return std.mem.readInt(u64, p[0..8], .big);
}
inline fn rdU32be(p: []const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .big);
}

// Read a big-endian window at `off` in the compressed data, ZERO-FILLING whatever falls past the
// end of it.
//
// The RE-PAIR decoder pulls 64- and 32-bit windows ahead of the symbol it is decoding, so on the
// final block of a table it reads a few bytes beyond the stored data. Upstream mmaps the file and
// those reads land in the mapping's page padding; zfish loads into a buffer sized to the file, so
// they used to land in the loader's 63-byte alignment slack -- reading whatever the arena happened
// to hold, past the end of any length the file states. The bits are never load-bearing (a valid
// table's symbol terminates before them), so define them as zero instead of leaving the answer to
// heap contents. Refusing the read instead is NOT equivalent: it moved tb-cursed's node counts.
fn windowBe(comptime T: type, data: []const u8, off: usize) T {
    const n = @sizeOf(T);
    if (off + n <= data.len) return std.mem.readInt(T, data[off..][0..n], .big);
    var tmp: [n]u8 = @splat(0);
    if (off < data.len) {
        const have = @min(n, data.len - off);
        @memcpy(tmp[0..have], data[off..][0..have]);
    }
    return std.mem.readInt(T, &tmp, .big);
}

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
    const visited = try gpa.alloc(bool, symlen_size);
    defer gpa.free(visited);
    @memset(visited, false);
    var sym: usize = 0;
    while (sym < symlen_size) : (sym += 1)
        if (!visited[sym]) {
            d.symlen[sym] = probe.setSymLen(d, @intCast(sym), visited);
        };

    p += symlen_size & 1;
    pos.* = p;
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

// Port SF `decompress_pairs`: return the stored value at index `idx`.
//
// This is the one decoder path that runs per probe, inside the search, so it carries no blanket
// `@setRuntimeSafety` -- setSizes validates at load everything that CAN be validated from the
// header (every region fits the file, every btree child indexes the tree), leaving this walk
// in-bounds by construction for a well-formed table. What the header cannot pin is the block
// CONTENT: `block` and `sym` are decoded from the compressed bitstream, so a corrupt payload can
// still drive them out of range. Those two are checked here and the probe refuses with 0 rather
// than reading off the table; the checks are a handful of predictable branches on a path the
// bench never takes (bench runs no tablebases).
pub fn decompressPairs(d: *const PairsData, idx: u64) i32 {
    if (d.flags & flag_single_value != 0) return d.min_sym_len;

    // Locate the block via the SparseIndex, then walk blockLength[] to the exact block.
    const k: u32 = @intCast(idx / d.span);
    const sparse = d.sparse_index;
    if (@as(usize, k) * 6 + 6 > sparse.len) return 0;
    var block: u32 = rdU32(sparse[@as(usize, k) * 6 ..]); // SparseEntry.block (bytes 0..4)
    var offset: i32 = rdU16(sparse[@as(usize, k) * 6 + 4 ..]); // .offset (bytes 4..6)

    const diff: i32 = @as(i32, @intCast(idx % d.span)) - @as(i32, @intCast(d.span / 2));
    offset += diff;

    const bl = d.block_length;
    const blocks = bl.len / 2;
    while (offset < 0) {
        if (block == 0) return 0;
        block -= 1;
        offset += @as(i32, rdU16(bl[@as(usize, block) * 2 ..])) + 1;
    }
    while (blk: {
        if (block >= blocks) break :blk false;
        break :blk offset > @as(i32, rdU16(bl[@as(usize, block) * 2 ..]));
    }) {
        offset -= @as(i32, rdU16(bl[@as(usize, block) * 2 ..])) + 1;
        block += 1;
    }
    if (block >= blocks) return 0;

    // Read the block's canonical-Huffman bitstream (big-endian 64-bit windows).
    const block_start = @as(u64, block) * d.sizeof_block;
    if (block_start >= d.data.len) return 0;
    var ptr: usize = @intCast(block_start);
    var buf64: u64 = windowBe(u64, d.data, ptr);
    ptr += 8;
    var buf64_size: i32 = 64;
    var sym: Sym = 0;

    while (true) {
        // `len` needs no bound: setSizes sets base64[base64_size - 1] = 0 and the right-pad
        // shift keeps it 0, so `buf64 < 0` is false for any u64 and the scan stops at
        // base64_size - 1 at the latest. lowest_sym is carved to exactly that many entries.
        var len: i32 = 0; // symbol length - min_sym_len
        while (buf64 < d.base64[@intCast(len)]) len += 1;
        sym = @intCast((buf64 - d.base64[@intCast(len)]) >>
            @intCast(64 - len - @as(i32, d.min_sym_len)));
        sym += rdSym(d.lowest_sym[@as(usize, @intCast(len)) * 2 ..]);

        if (sym >= d.symlen.len) return 0; // decoded from the payload: not header-checkable
        if (offset < @as(i32, d.symlen[sym]) + 1) break;

        offset -= @as(i32, d.symlen[sym]) + 1;
        len += d.min_sym_len; // real length
        buf64 <<= @intCast(len);
        buf64_size -= len;
        if (buf64_size <= 32) {
            buf64_size += 32;
            buf64 |= @as(u64, windowBe(u32, d.data, ptr)) << @intCast(64 - buf64_size);
            ptr += 4;
        }
    }

    // Recursively expand the symbol down to the leaf holding the value. Every child here is
    // in-bounds by the btree validation setSizes ran at load.
    while (d.symlen[sym] != 0) {
        const left = d.btree[sym].left();
        if (offset < @as(i32, d.symlen[left]) + 1) {
            sym = left;
        } else {
            offset -= @as(i32, d.symlen[left]) + 1;
            sym = d.btree[sym].right();
        }
    }
    return d.btree[sym].left();
}

test "decompressPairs SingleValue returns the stored value" {
    var d = PairsData{};
    d.flags = flag_single_value;
    d.min_sym_len = 3; // e.g. WDL value stored directly
    try std.testing.expectEqual(@as(i32, 3), decompressPairs(&d, 0));
    try std.testing.expectEqual(@as(i32, 3), decompressPairs(&d, 12345));
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
