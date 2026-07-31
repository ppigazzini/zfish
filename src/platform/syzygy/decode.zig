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
//! offset here comes out of it. This file is the PROBE-time half -- decompressPairs, which runs
//! inside the search and therefore checks only what the header could not pin (the block and symbol
//! the payload decodes to). The LOAD-time half, `setSizes`, lives in decode_header.zig, which
//! carves each file-backed region with a bound and refuses a table that cannot keep its own size
//! promises. The dependency runs decode_header -> decode; never the reverse.
//! See docs/05-tablebases.md.

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
pub inline fn rdU16(p: []const u8) u16 {
    return std.mem.readInt(u16, p[0..2], .little);
}
pub inline fn rdU32(p: []const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}
pub inline fn rdSym(p: []const u8) Sym {
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
    // Refuse `block` BEFORE either walk. It is a raw 32-bit field of the sparse-index payload,
    // so no header value bounds it, and the BACKWARD walk only tested `block == 0` before
    // reading block_length[block] -- an out-of-bounds read up to ~8 GiB past the region (found
    // by mcfish's libFuzzer harness, mcfish 9fe1c021; reproduced here as the regression test
    // below). One test covers every index the backward walk reads, because it only decrements;
    // the forward walk keeps its own, because it increments. A well-formed table always
    // satisfies this -- block_length_size is blocks_num plus the padding.
    if (block >= blocks) return 0;
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
        // Narrow and add the way upstream's `Sym` arithmetic does -- a C implicit conversion
        // to uint16_t truncates, and uint16_t addition wraps. The shift leaves up to
        // max_sym_len (< 64) bits, so on a corrupt table the value exceeds u16: @intCast would
        // be an illegal cast (ReleaseFast UB) where upstream simply truncates. Both forms agree
        // on every valid table, where the canonical code guarantees the symbol fits.
        sym = @truncate((buf64 - d.base64[@intCast(len)]) >>
            @intCast(64 - len - @as(i32, d.min_sym_len)));
        sym +%= rdSym(d.lowest_sym[@as(usize, @intCast(len)) * 2 ..]);

        if (sym >= d.symlen.len) return 0; // decoded from the payload: not header-checkable
        if (offset < @as(i32, d.symlen[sym]) + 1) break;

        offset -= @as(i32, d.symlen[sym]) + 1;
        len += d.min_sym_len; // real length
        buf64 <<= @intCast(len);
        buf64_size -= len;
        if (buf64_size <= 32) {
            buf64_size += 32;
            // Refuse a window the symbol lengths have driven out of range. A valid table never
            // consumes more bits than the window holds, so this stays above zero; a corrupt one
            // can decode symbols long enough to walk it negative, and `64 - buf64_size` would
            // then exceed 63 -- an illegal shift width (mcfish 9fe1c021, where the same value
            // tripped UBSan's "shift exponent 64 is too large").
            if (buf64_size <= 0) return 0;
            buf64 |= @as(u64, windowBe(u32, d.data, ptr)) << @intCast(64 - buf64_size);
            ptr += 4;
        }
    }

    // Expand the symbol down to the leaf holding the value. Every child is in RANGE by the
    // btree validation setSizes ran at load -- but range is not termination. The tree is
    // acyclic only because a valid file says so, and a corrupt one can name a child that is
    // the node itself, which loops here forever: a HANG, not a crash, and therefore the one
    // failure mode a crash-oriented fuzzer reports as a timeout rather than a bug (mcfish
    // 9fe1c021 measured one such input holding its fuzzer over seven minutes).
    //
    // Bound it by the invariant setSymLen itself establishes: a well-formed btree has
    // symlen[s] == symlen[left] + symlen[right] + 1, so every step strictly shrinks symlen.
    // Requiring that cannot fire on a valid table and makes the descent terminate on any.
    while (d.symlen[sym] != 0) {
        const here = d.symlen[sym];
        const left = d.btree[sym].left();
        var next: Sym = undefined;
        if (offset < @as(i32, d.symlen[left]) + 1) {
            next = left;
        } else {
            offset -= @as(i32, d.symlen[left]) + 1;
            next = d.btree[sym].right();
        }
        if (d.symlen[next] >= here) return 0;
        sym = next;
    }
    return d.btree[sym].left();
}

// Build a minimal non-SingleValue PairsData over caller-owned regions, so the decompressPairs
// bounds below can be driven directly without a real table file.
const StubTable = struct {
    sparse: [6]u8,
    bl: [4]u8 = @splat(0),
    data: [64]u8 = @splat(0),
    base64: [1]u64 = .{0},
    symlen: [2]u8 = .{ 0, 0 },
    btree: [2]probe.LR = .{ .{ .lr = .{ 0, 0xF0, 0xFF } }, .{ .lr = .{ 0, 0xF0, 0xFF } } },
    lowest: [2]u8 = .{ 0, 0 },

    fn pairs(self: *@This()) PairsData {
        var d = PairsData{};
        d.span = 64;
        d.sizeof_block = 64;
        d.min_sym_len = 1;
        d.max_sym_len = 1;
        d.block_length_size = 2;
        d.sparse_index = &self.sparse;
        d.block_length = &self.bl;
        d.data = &self.data;
        d.base64 = &self.base64;
        d.symlen = &self.symlen;
        d.btree = &self.btree;
        d.lowest_sym = &self.lowest;
        return d;
    }
};

test "decompressPairs refuses a sparse-index block past the block-length region" {
    // `block` is a raw u32 of the payload. With offset driven negative (idx 0 -> diff -32) the
    // BACKWARD walk decrements and reads block_length[block]; unbounded, that is an ~8 GiB
    // out-of-bounds read. Regression for mcfish 9fe1c021.
    var stub = StubTable{ .sparse = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0, 0 } };
    var d = stub.pairs();
    try std.testing.expectEqual(@as(i32, 0), decompressPairs(&d, 0));
}

test "decompressPairs terminates on a btree child that does not shrink" {
    // A corrupt btree can name a child that is the node itself; the descent would then never
    // terminate -- a hang rather than a crash. symlen must strictly shrink each step.
    var stub = StubTable{ .sparse = .{ 0, 0, 0, 0, 0, 0 } };
    // Symbol 0 is a non-leaf whose children are both symbol 0, with a non-zero symlen.
    stub.btree[0] = .{ .lr = .{ 0, 0x00, 0x00 } }; // left = 0, right = 0 (not the 0xFFF leaf)
    stub.symlen[0] = 5;
    var d = stub.pairs();
    // Any decode reaching the descent must return rather than spin.
    try std.testing.expectEqual(@as(i32, 0), decompressPairs(&d, 0));
}

test "decompressPairs SingleValue returns the stored value" {
    var d = PairsData{};
    d.flags = flag_single_value;
    d.min_sym_len = 3; // e.g. WDL value stored directly
    try std.testing.expectEqual(@as(i32, 3), decompressPairs(&d, 0));
    try std.testing.expectEqual(@as(i32, 3), decompressPairs(&d, 12345));
}
