//! Syzygy WDL-probe data model + pure indexing helpers. The structs (LR btree entry,
//! PairsData, TBTable) mirror Stockfish's, and the pure functions `setGroups` (split the piece
//! sequence into encoding groups) and `setSymLen` (expand the RE-PAIR Huffman btree) are ported
//! and unit-tested WITHOUT a live file -- the file-mmap orchestration (`do_init`) and the probe
//! itself (`decompress_pairs`/`do_probe_table`) are in decode.zig / wdl.zig, where the whole chain is gated
//! bit-exact vs the oracle. Dead until then; bench unchanged.

const std = @import("std");
const encode = @import("encode.zig");

pub const tb_pieces = 7; // SF TBPIECES: max supported men
pub const Sym = u16; // Huffman symbol

// A RE-PAIR btree entry: 3 bytes packing two 12-bit symbols (left child, right child). If the
// symbol has length 1 the left field is the stored value; right == 0xFFF marks a leaf.
pub const LR = extern struct {
    lr: [3]u8,
    pub inline fn left(self: LR) Sym {
        return (@as(Sym, self.lr[1] & 0xF) << 8) | self.lr[0];
    }
    pub inline fn right(self: LR) Sym {
        return (@as(Sym, self.lr[2]) << 4) | (self.lr[1] >> 4);
    }
};

comptime {
    std.debug.assert(@sizeOf(LR) == 3);
}

// A partial index into blockLength[] (SF SparseEntry: `char block[4]; offset[2]`, read LE at
// access time -- byte arrays so it is exactly 6 bytes with no padding).
pub const SparseEntry = extern struct { block: [4]u8, offset: [2]u8 };

comptime {
    std.debug.assert(@sizeOf(SparseEntry) == 6);
}

// Low-level indexing/decompression state for one (side, file) of a table. The `[*]`-typed fields
// point into the mmap'd file and are filled by registry.set; the slices are owned.
pub const PairsData = struct {
    flags: u8 = 0,
    max_sym_len: u8 = 0,
    min_sym_len: u8 = 0,
    blocks_num: u32 = 0,
    sizeof_block: usize = 0,
    span: usize = 0,
    lowest_sym: ?[*]const u8 = null, // Sym[] in the file (unaligned LE)
    btree: []const LR = &.{},
    block_length: ?[*]const u8 = null, // u16[] in the file
    block_length_size: u32 = 0,
    sparse_index: ?[*]const u8 = null, // SparseEntry[] in the file
    sparse_index_size: usize = 0,
    data: ?[*]const u8 = null,
    base64: []u64 = &.{},
    symlen: []u8 = &.{},
    pieces: [tb_pieces]u8 = [_]u8{0} ** tb_pieces,
    group_idx: [tb_pieces + 1]u64 = [_]u64{0} ** (tb_pieces + 1),
    group_len: [tb_pieces + 1]i32 = [_]i32{0} ** (tb_pieces + 1),
    map_idx: [4]u16 = [_]u16{0} ** 4,
};

// The per-table metadata (built at init from the material config); PairsData is filled lazily.
pub const EntryInfo = struct {
    has_pawns: bool,
    has_unique_pieces: bool,
    piece_count: i32,
    pawn_count: [2]u8, // [lead color, other color]
};

// SF `set_groups`: from the piece sequence in d.pieces, fill group_len[] (0-terminated) and
// group_idx[] (the multiplicative start index of each group). `order` + `f` come from the file
// header. Uses encode.binomial / encode.lead_pawns_size.
pub fn setGroups(d: *PairsData, e: EntryInfo, order: [2]i32, f: usize) void {
    var n: usize = 0;
    var first_len: i32 = if (e.has_pawns) 0 else if (e.has_unique_pieces) 3 else 2;
    d.group_len[0] = 1;

    var i: usize = 1;
    while (i < @as(usize, @intCast(e.piece_count))) : (i += 1) {
        first_len -= 1;
        if (first_len > 0 or d.pieces[i] == d.pieces[i - 1]) {
            d.group_len[n] += 1;
        } else {
            n += 1;
            d.group_len[n] = 1;
        }
    }
    n += 1;
    d.group_len[n] = 0; // zero-terminated

    const pp = e.has_pawns and e.pawn_count[1] != 0; // pawns on both sides
    var next: usize = if (pp) 2 else 1;
    var free_squares: i32 = 64 - d.group_len[0] - (if (pp) d.group_len[1] else 0);
    var idx: u64 = 1;

    var k: i32 = 0;
    while (@as(usize, @intCast(next)) < n or k == order[0] or k == order[1]) : (k += 1) {
        if (k == order[0]) { // leading pawns or pieces
            d.group_idx[0] = idx;
            const mult: u64 = if (e.has_pawns)
                @intCast(encode.lead_pawns_size[@intCast(d.group_len[0])][f])
            else if (e.has_unique_pieces)
                31332
            else
                462;
            idx *= mult;
        } else if (k == order[1]) { // remaining pawns
            d.group_idx[1] = idx;
            idx *= @intCast(encode.binomial[@intCast(d.group_len[1])][@intCast(48 - d.group_len[0])]);
        } else { // remaining pieces
            d.group_idx[next] = idx;
            idx *= @intCast(encode.binomial[@intCast(d.group_len[next])][@intCast(free_squares)]);
            free_squares -= d.group_len[next];
            next += 1;
        }
    }
    d.group_idx[n] = idx;
}

// SF `set_symlen`: expand btree symbol `s` into its children until the leaves, returning the
// number of values it represents (minus 1). Recursive; the tree is acyclic so `visited` guards
// re-entry. Fills d.symlen[].
pub fn setSymLen(d: *PairsData, s: Sym, visited: []bool) u8 {
    visited[s] = true; // safe now: the tree is acyclic
    const sr = d.btree[s].right();
    if (sr == 0xFFF) return 0; // leaf

    const sl = d.btree[s].left();
    if (!visited[sl]) d.symlen[sl] = setSymLen(d, sl, visited);
    if (!visited[sr]) d.symlen[sr] = setSymLen(d, sr, visited);
    return d.symlen[sl] + d.symlen[sr] + 1;
}

// ---- unit tests (no live file) ---------------------------------------------

test "LR unpacks two 12-bit symbols from 3 bytes" {
    // left = ((lr[1]&0xF)<<8)|lr[0]; right = (lr[2]<<4)|(lr[1]>>4).
    const e = LR{ .lr = .{ 0x34, 0x92, 0x56 } };
    try std.testing.expectEqual(@as(Sym, (0x2 << 8) | 0x34), e.left()); // 0x234
    try std.testing.expectEqual(@as(Sym, (0x56 << 4) | 0x9), e.right()); // 0x569
    const leaf = LR{ .lr = .{ 0x07, 0xF0, 0xFF } };
    try std.testing.expectEqual(@as(Sym, 0xFFF), leaf.right()); // leaf marker
}

test "setGroups splits distinct pieces like SF (KRKN -> (3,1), 3-man -> (3))" {
    encode.initGeometry();
    // 4 distinct pieces (e.g. KRKN): hasUnique, no pawns -> group_len (3,1,0).
    var d = PairsData{};
    d.pieces = .{ 6, 4, 6, 2, 0, 0, 0 }; // K R K N (values distinct enough)
    setGroups(&d, .{ .has_pawns = false, .has_unique_pieces = true, .piece_count = 4, .pawn_count = .{ 0, 0 } }, .{ 0, 15 }, 0);
    try std.testing.expectEqual(@as(i32, 3), d.group_len[0]);
    try std.testing.expectEqual(@as(i32, 1), d.group_len[1]);
    try std.testing.expectEqual(@as(i32, 0), d.group_len[2]); // zero-terminated
    try std.testing.expectEqual(@as(u64, 1), d.group_idx[0]); // first group starts at 1

    // 3-man KRvK: K R K -> single group (3).
    var d3 = PairsData{};
    d3.pieces = .{ 6, 4, 6, 0, 0, 0, 0 };
    setGroups(&d3, .{ .has_pawns = false, .has_unique_pieces = true, .piece_count = 3, .pawn_count = .{ 0, 0 } }, .{ 0, 15 }, 0);
    try std.testing.expectEqual(@as(i32, 3), d3.group_len[0]);
    try std.testing.expectEqual(@as(i32, 0), d3.group_len[1]);
}

test "setSymLen expands a synthetic RE-PAIR btree" {
    // Symbols: 0,1 = leaves (right == 0xFFF); 2 = pair(0,1); 3 = pair(2, 0).
    var btree = [_]LR{
        .{ .lr = .{ 0, 0xF0, 0xFF } }, // 0: leaf
        .{ .lr = .{ 0, 0xF0, 0xFF } }, // 1: leaf
        pair(0, 1), // 2: (0,1)
        pair(2, 0), // 3: (2,0)
    };
    var symlen = [_]u8{ 0, 0, 0, 0 };
    var visited = [_]bool{ false, false, false, false };
    var d = PairsData{ .btree = &btree, .symlen = &symlen };
    // sym 2 expands to leaves 0,1 -> 2 values -> symlen 1.
    try std.testing.expectEqual(@as(u8, 1), setSymLen(&d, 2, &visited));
    // sym 3 = (2,0) -> symlen[2] + symlen[0] + 1 = 1 + 0 + 1 = 2.
    var visited2 = [_]bool{ false, false, false, false };
    try std.testing.expectEqual(@as(u8, 2), setSymLen(&d, 3, &visited2));
}

fn pair(l: Sym, r: Sym) LR {
    // Inverse of LR.left/right: lr[0]=l&0xFF, lr[1]=(l>>8)|((r&0xF)<<4), lr[2]=r>>4.
    return .{ .lr = .{
        @intCast(l & 0xFF),
        @intCast((l >> 8) | ((r & 0xF) << 4)),
        @intCast(r >> 4),
    } };
}
