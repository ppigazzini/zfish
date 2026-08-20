//! Define the Syzygy WDL-probe data model + pure indexing helpers. Mirror Stockfish's structs (LR btree entry,
//! PairsData, TBTable), and port + unit-test the pure functions `setGroups` (split the piece
//! sequence into encoding groups) and `setSymLen` (expand the RE-PAIR Huffman btree)
//! WITHOUT a live file -- the file-mmap orchestration (`do_init`) and the probe
//! itself (`decompress_pairs`/`do_probe_table`) are in decode.zig / wdl.zig, where the whole chain is gated
//! bit-exact vs the oracle. Treat as dead until then; bench unchanged.

const std = @import("std");
const encode = @import("encode.zig");

pub const tb_pieces = 7; // SF TBPIECES: max supported men
pub const Sym = u16; // Huffman symbol

// Represent a RE-PAIR btree entry: 3 bytes packing two 12-bit symbols (left child, right child). If the
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

// Hold a partial index into blockLength[] (SF SparseEntry: `char block[4]; offset[2]`, read LE at
// access time -- byte arrays so it is exactly 6 bytes with no padding).
pub const SparseEntry = extern struct { block: [4]u8, offset: [2]u8 };

comptime {
    std.debug.assert(@sizeOf(SparseEntry) == 6);
}

// Hold low-level indexing/decompression state for one (side, file) of a table. The file-backed
// fields are SLICES into the loaded table bytes, not `[*]` pointers: the table is an untrusted
// external file, and a many-item pointer carries no length for either the parse or the decoder to
// check against. table_load.set fills them by carving `buf` with a bound (`take`), so a truncated
// file is rejected at load; the remaining slices are owned allocations.
// Stand in for the bucket table on a PairsData nothing has filled -- the SingleValue branch,
// a hand-built stub, a fuzzer's partial parse. Two entries and a shift of 63 index in range for
// any word and name index 0, which is where the scan started before there was a table at all.
const walk_from_zero: [2]u8 = .{ 0, 0 };

pub const PairsData = struct {
    flags: u8 = 0,
    max_sym_len: u8 = 0,
    min_sym_len: u8 = 0,
    blocks_num: u32 = 0,
    sizeof_block: usize = 0,
    span: usize = 0,
    lowest_sym: []const u8 = &.{}, // Sym[] in the file (unaligned LE)
    btree: []const LR = &.{},
    block_length: []const u8 = &.{}, // u16[] in the file
    block_length_size: u32 = 0,
    sparse_index: []const u8 = &.{}, // SparseEntry[] in the file
    sparse_index_size: usize = 0,
    data: []const u8 = &.{},
    base64: []u64 = &.{},
    symlen: []u8 = &.{},
    // Answer the decode loop's per-symbol questions from a load-time table instead of
    // recomputing them per symbol. All four are filled by decode_header.setSizes and are
    // indexed by `len` -- the base64[] index, i.e. the code length minus min_sym_len.
    //
    // `len_tab` maps the top `64 - len_tab_shift` bits of the bitstream word to a LOWER
    // BOUND on that word's `len`, so the scan resumes there instead of at zero. A code no
    // longer than the index width owns a whole number of buckets (base64[] is right-padded
    // to 64 bits, so both ends of a length's span land on a bucket boundary), which makes
    // the answer exact for those; a bucket no such length covers holds the first index a
    // longer code can occupy. Either way the value never exceeds the true `len`, so the
    // scan below it stays correct without a sentinel or a branch.
    len_tab: []const u8 = &walk_from_zero,
    len_tab_shift: u6 = 63,
    // The three values the loop derives from `len` alone: the right-pad shift, the folded
    // symbol offset (lowest_sym[len] minus base64[len] >> shift, mod 2^16 -- see the
    // decoder), and the real code length the consumed word is shifted by. Inline rather
    // than allocated: base64_size is at most 63, so all three fit beside the pointers and
    // each index folds into its own load's addressing.
    shift_tab: [64]u6 = @splat(0),
    off_tab: [64]u16 = @splat(0),
    real_len_tab: [64]u8 = @splat(0),
    pieces: [tb_pieces]u8 = @splat(0),
    group_idx: [tb_pieces + 1]u64 = @splat(0),
    group_len: [tb_pieces + 1]i32 = @splat(0),
    map_idx: [4]u16 = @splat(0),
};

// Release the allocations setSizes owns on this PairsData.
//
// Skip the bucket table when it is still the shared walk-from-zero default: that is static
// storage, not an allocation, and a PairsData that never reached the table build -- the
// SingleValue branch, a header refused before it -- still carries it. The shipped loader frees
// through an arena and never calls this; the fuzz targets and any test holding a checking
// allocator do.
pub fn freeOwned(d: *PairsData, gpa: std.mem.Allocator) void {
    gpa.free(d.base64);
    gpa.free(d.symlen);
    if (@intFromPtr(d.len_tab.ptr) != @intFromPtr(&walk_from_zero)) gpa.free(@constCast(d.len_tab));
    d.base64 = &.{};
    d.symlen = &.{};
    d.len_tab = &walk_from_zero;
}

// Hold the per-table metadata (built at init from the material config); PairsData is filled lazily.
pub const EntryInfo = struct {
    has_pawns: bool,
    has_unique_pieces: bool,
    piece_count: i32,
    pawn_count: [2]u8, // [lead color, other color]
};

// Report the geometry-table row a group length may index, or null when the piece sequence has
// produced a group no real table has. `binomial` and `lead_pawns_size` are sized for the longest
// group a legal material configuration can make (5 -- seven men, two of them kings); the piece
// sequence they are indexed by is a run of raw file NIBBLES, so a corrupt table can make a group
// longer than that and read off the end of the array. Upstream indexes both unchecked, its own
// writer having produced the file.
fn geometryRow(len: i32, rows: usize) ?usize {
    if (len < 0 or @as(usize, @intCast(len)) >= rows) return null;
    return @intCast(len);
}

// Port SF `set_groups`: from the piece sequence in d.pieces, fill group_len[] (0-terminated) and
// group_idx[] (the multiplicative start index of each group). `order` + `f` come from the file
// header. Use encode.binomial / encode.lead_pawns_size.
//
// Return false when the sequence indexes past either geometry table, so the caller refuses the
// table at LOAD -- the one point where a corrupt file can still be answered with "no table"
// instead of a probe reading off the end of the arrays.
pub fn setGroups(d: *PairsData, e: EntryInfo, order: [2]i32, f: encode.TbFile) bool {
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
            const mult: u64 = if (e.has_pawns) blk: {
                const row = geometryRow(d.group_len[0], encode.lead_pawns_size.len) orelse
                    return false;
                break :blk @intCast(encode.lead_pawns_size[row][f.index()]);
            } else if (e.has_unique_pieces)
                31332
            else
                462;
            idx *= mult;
        } else if (k == order[1]) { // remaining pawns
            d.group_idx[1] = idx;
            const row = geometryRow(d.group_len[1], encode.binomial.len) orelse return false;
            idx *= @intCast(encode.binomial[row][@intCast(48 - d.group_len[0])]);
        } else { // remaining pieces
            d.group_idx[next] = idx;
            const row = geometryRow(d.group_len[next], encode.binomial.len) orelse return false;
            idx *= @intCast(encode.binomial[row][@intCast(free_squares)]);
            free_squares -= d.group_len[next];
            next += 1;
        }
    }
    d.group_idx[n] = idx;
    return true;
}

// Port SF `set_symlen`: expand btree symbol `s` into its children until the leaves, returning the
// number of values it represents (minus 1). Recurse; the tree is acyclic so `visited` guards
// re-entry. Fill d.symlen[].
//
// PRECONDITION, and it is load-bearing: every non-leaf btree entry's two child symbols index
// inside d.btree / d.symlen / visited. Both children are 12-bit fields of the FILE, so a corrupt
// table can name a symbol past the tree -- and `d.symlen[sl] = ...` below would then be an
// out-of-bounds WRITE, which ReleaseFast does not check. decode.setSizes validates the whole
// btree before calling here, so this walk is in-bounds by construction rather than by trust; the
// asserts restate that where ReleaseSafe (tests, fuzz) can see it.
// Colour a symbol during the btree walk. GREY means "on the current DFS path", so meeting a
// GREY child IS a cycle. Two states cannot express that: a symbol has to be marked before its
// subtree is walked, which makes a cycle read as "already computed" -- the walk terminates and
// sums symlen[] entries that are still zero.
pub const SymColour = enum(u8) { white, grey, black };

pub fn setSymLen(d: *PairsData, s: Sym, colour: []SymColour, cyclic: *bool) u8 {
    std.debug.assert(s < d.btree.len and s < d.symlen.len and s < colour.len);
    colour[s] = .grey;
    const sr = d.btree[s].right();
    if (sr == 0xFFF) { // leaf
        colour[s] = .black;
        return 0;
    }

    const sl = d.btree[s].left();
    // Either child still on the path closes a cycle: report it and stop descending. The caller
    // refuses the whole table, so the value returned here is never read.
    if (colour[sl] == .grey or colour[sr] == .grey) {
        cyclic.* = true;
        colour[s] = .black;
        return 0;
    }

    if (colour[sl] == .white) d.symlen[sl] = setSymLen(d, sl, colour, cyclic);
    if (colour[sr] == .white) d.symlen[sr] = setSymLen(d, sr, colour, cyclic);
    colour[s] = .black;
    // Wrap rather than trap. Upstream promotes both operands to int and truncates the sum back
    // into the u8 return, which is defined; a valid table's lengths fit u8 by construction, so
    // this is bit-identical there and only a corrupt tree can reach the wrap.
    return d.symlen[sl] +% d.symlen[sr] +% 1;
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
    try std.testing.expect(setGroups(&d, .{ .has_pawns = false, .has_unique_pieces = true, .piece_count = 4, .pawn_count = .{ 0, 0 } }, .{ 0, 15 }, .ah));
    try std.testing.expectEqual(@as(i32, 3), d.group_len[0]);
    try std.testing.expectEqual(@as(i32, 1), d.group_len[1]);
    try std.testing.expectEqual(@as(i32, 0), d.group_len[2]); // zero-terminated
    try std.testing.expectEqual(@as(u64, 1), d.group_idx[0]); // first group starts at 1

    // 3-man KRvK: K R K -> single group (3).
    var d3 = PairsData{};
    d3.pieces = .{ 6, 4, 6, 0, 0, 0, 0 };
    try std.testing.expect(setGroups(&d3, .{ .has_pawns = false, .has_unique_pieces = true, .piece_count = 3, .pawn_count = .{ 0, 0 } }, .{ 0, 15 }, .ah));
    try std.testing.expectEqual(@as(i32, 3), d3.group_len[0]);
    try std.testing.expectEqual(@as(i32, 0), d3.group_len[1]);
}

test "setGroups refuses a piece run longer than any geometry row" {
    encode.initGeometry();
    // Seven identical pawn nibbles: the leading group swallows the whole sequence, so
    // group_len[0] is 7 where LeadPawnsSize has six rows. A legal 7-man configuration cannot
    // reach it (two of the seven men are kings), a corrupt file can.
    var d = PairsData{};
    d.pieces = @splat(1);
    try std.testing.expect(!setGroups(
        &d,
        .{ .has_pawns = true, .has_unique_pieces = false, .piece_count = 7, .pawn_count = .{ 5, 0 } },
        .{ 0, 15 },
        .ah,
    ));

    // The second group indexes Binomial, which has six rows: one leading pawn and six of the
    // other colour's overruns it. Pawns on both sides (pawn_count[1] != 0) is what routes the
    // group through order[1] at all.
    var d2 = PairsData{};
    d2.pieces = .{ 1, 9, 9, 9, 9, 9, 9 };
    try std.testing.expect(!setGroups(
        &d2,
        .{ .has_pawns = true, .has_unique_pieces = false, .piece_count = 7, .pawn_count = .{ 1, 6 } },
        .{ 0, 1 },
        .ah,
    ));
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
    var colour = [_]SymColour{ .white, .white, .white, .white };
    var cyclic = false;
    var d = PairsData{ .btree = &btree, .symlen = &symlen };
    // Expect sym 2 to expand to leaves 0,1 -> 2 values -> symlen 1.
    try std.testing.expectEqual(@as(u8, 1), setSymLen(&d, 2, &colour, &cyclic));
    // sym 3 = (2,0) -> symlen[2] + symlen[0] + 1 = 1 + 0 + 1 = 2.
    var colour2 = [_]SymColour{ .white, .white, .white, .white };
    try std.testing.expectEqual(@as(u8, 2), setSymLen(&d, 3, &colour2, &cyclic));
    try std.testing.expect(!cyclic);
}

test "setSymLen reports a cyclic btree instead of summing zeros" {
    // 0 = leaf; 1 = pair(2, 0); 2 = pair(1, 0). Walking 1 descends to 2, which names 1 again.
    // Two states read that as "already computed", leave symlen[1] at 0 and accept the table;
    // the caller refuses it on `cyclic`.
    var btree = [_]LR{
        .{ .lr = .{ 0, 0xF0, 0xFF } }, // 0: leaf
        pair(2, 0), // 1: (2,0)
        pair(1, 0), // 2: (1,0)
    };
    var symlen = [_]u8{ 0, 0, 0 };
    var colour = [_]SymColour{ .white, .white, .white };
    var cyclic = false;
    var d = PairsData{ .btree = &btree, .symlen = &symlen };
    _ = setSymLen(&d, 1, &colour, &cyclic);
    try std.testing.expect(cyclic);
}

fn pair(l: Sym, r: Sym) LR {
    // Invert LR.left/right: lr[0]=l&0xFF, lr[1]=(l>>8)|((r&0xF)<<4), lr[2]=r>>4.
    return .{ .lr = .{
        @intCast(l & 0xFF),
        @intCast((l >> 8) | ((r & 0xF) << 4)),
        @intCast(r >> 4),
    } };
}
