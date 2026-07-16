//! Parse Syzygy files and RE-PAIR-decompress them. Port Stockfish's
//! `set_sizes` faithfully (parse one PairsData's header out of the mmapped file) and `decompress_pairs`
//! (given a value index, walk the SparseIndex/blockLength and decode the canonical-Huffman
//! symbol via the btree). Read each `number<T,LE/BE>` as std.mem.readInt (all zfish targets
//! are little-endian, so LittleEndian reads are native, BigEndian reads byte-swap).
//!
//! Treat these as the decoder half (WIP): do_probe_table (position->index) + probe_wdl + wiring land in
//! part 2, where the whole chain is gated bit-exact vs the oracle (`tb-wdl`). Note that only the SingleValue
//! path of decompress_pairs is independently testable here; the rest is validated end-to-end.
//! Walk bounds-checked slices, not raw pointer walks (the RE-PAIR loop is D2-shaped under ReleaseSafe).

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

// Read unaligned little-/big-endian values from a file byte pointer (SF `number<T, LE/BE>`).
inline fn rdU16(p: [*]const u8) u16 {
    return std.mem.readInt(u16, @ptrCast(p), .little);
}
inline fn rdU32(p: [*]const u8) u32 {
    return std.mem.readInt(u32, @ptrCast(p), .little);
}
inline fn rdSym(p: [*]const u8) Sym {
    return std.mem.readInt(u16, @ptrCast(p), .little);
}
inline fn rdU64be(p: [*]const u8) u64 {
    return std.mem.readInt(u64, @ptrCast(p), .big);
}
inline fn rdU32be(p: [*]const u8) u32 {
    return std.mem.readInt(u32, @ptrCast(p), .big);
}

// Port SF `set_sizes`: parse the header for one PairsData starting at `buf[pos]`, allocate base64[]
// and symlen[], set the file pointers, and advance `pos` past the btree. group_len/group_idx must
// already be filled (setGroups). Return an error only on OOM.
pub fn setSizes(gpa: std.mem.Allocator, d: *PairsData, buf: []const u8, pos: *usize) !void {
    var p = pos.*;
    d.flags = buf[p];
    p += 1;

    if (d.flags & flag_single_value != 0) {
        d.blocks_num = 0;
        d.block_length_size = 0;
        d.span = 0;
        d.sparse_index_size = 0;
        d.min_sym_len = buf[p]; // the single stored value
        p += 1;
        pos.* = p;
        return;
    }

    // Compute tbSize as group_idx at the group_len[] terminator index.
    var term: usize = 0;
    while (term < probe.tb_pieces and d.group_len[term] != 0) term += 1;
    const tb_size: u64 = d.group_idx[term];

    d.sizeof_block = @as(usize, 1) << @intCast(buf[p]);
    p += 1;
    d.span = @as(usize, 1) << @intCast(buf[p]);
    p += 1;
    d.sparse_index_size = (tb_size + d.span - 1) / d.span; // round up
    const padding: u8 = buf[p];
    p += 1;
    d.blocks_num = rdU32(buf[p..].ptr);
    p += 4;
    d.block_length_size = d.blocks_num + padding;
    d.max_sym_len = buf[p];
    p += 1;
    d.min_sym_len = buf[p];
    p += 1;
    d.lowest_sym = buf[p..].ptr; // Sym[] in the file

    const base64_size: usize = @as(usize, d.max_sym_len - d.min_sym_len) + 1;
    d.base64 = try gpa.alloc(u64, base64_size);

    // Build canonical Huffman: base64[i] >= base64[i+1] (see SF). base64[last] starts at 0.
    d.base64[base64_size - 1] = 0;
    var i: i32 = @as(i32, @intCast(base64_size)) - 2;
    while (i >= 0) : (i -= 1) {
        const ui: usize = @intCast(i);
        d.base64[ui] = (d.base64[ui + 1] +
            @as(u64, rdSym(d.lowest_sym.? + ui * 2)) -
            @as(u64, rdSym(d.lowest_sym.? + (ui + 1) * 2))) / 2;
    }
    i = 0;
    while (i < @as(i32, @intCast(base64_size))) : (i += 1) {
        const ui: usize = @intCast(i);
        const shift: u6 = @intCast(64 - i - @as(i32, d.min_sym_len));
        d.base64[ui] <<= shift; // right-pad to 64 bits
    }

    p += base64_size * 2; // sizeof(Sym)
    const symlen_size: usize = rdU16(buf[p..].ptr);
    p += 2;
    d.btree = @as([*]const probe.LR, @ptrCast(@alignCast(buf[p..].ptr)))[0..symlen_size];

    d.symlen = try gpa.alloc(u8, symlen_size);
    @memset(d.symlen, 0);
    const visited = try gpa.alloc(bool, symlen_size);
    defer gpa.free(visited);
    @memset(visited, false);
    var sym: usize = 0;
    while (sym < symlen_size) : (sym += 1)
        if (!visited[sym]) {
            d.symlen[sym] = probe.setSymLen(d, @intCast(sym), visited);
        };

    p += symlen_size * @sizeOf(probe.LR) + (symlen_size & 1);
    pos.* = p;
}

// Port SF `decompress_pairs`: return the stored value at index `idx`.
pub fn decompressPairs(d: *const PairsData, idx: u64) i32 {
    if (d.flags & flag_single_value != 0) return d.min_sym_len;

    // Locate the block via the SparseIndex, then walk blockLength[] to the exact block.
    const k: u32 = @intCast(idx / d.span);
    const sparse = d.sparse_index.?;
    var block: u32 = rdU32(sparse + @as(usize, k) * 6); // SparseEntry.block (bytes 0..4)
    var offset: i32 = rdU16(sparse + @as(usize, k) * 6 + 4); // .offset (bytes 4..6)

    const diff: i32 = @as(i32, @intCast(idx % d.span)) - @as(i32, @intCast(d.span / 2));
    offset += diff;

    const bl = d.block_length.?;
    while (offset < 0) {
        block -= 1;
        offset += @as(i32, rdU16(bl + @as(usize, block) * 2)) + 1;
    }
    while (offset > @as(i32, rdU16(bl + @as(usize, block) * 2))) {
        offset -= @as(i32, rdU16(bl + @as(usize, block) * 2)) + 1;
        block += 1;
    }

    // Read the block's canonical-Huffman bitstream (big-endian 64-bit windows).
    var ptr: [*]const u8 = d.data.? + @as(u64, block) * d.sizeof_block;
    var buf64: u64 = rdU64be(ptr);
    ptr += 8;
    var buf64_size: i32 = 64;
    var sym: Sym = 0;

    while (true) {
        var len: i32 = 0; // symbol length - min_sym_len
        while (buf64 < d.base64[@intCast(len)]) len += 1;
        sym = @intCast((buf64 - d.base64[@intCast(len)]) >>
            @intCast(64 - len - @as(i32, d.min_sym_len)));
        sym += rdSym(d.lowest_sym.? + @as(usize, @intCast(len)) * 2);

        if (offset < @as(i32, d.symlen[sym]) + 1) break;

        offset -= @as(i32, d.symlen[sym]) + 1;
        len += d.min_sym_len; // real length
        buf64 <<= @intCast(len);
        buf64_size -= len;
        if (buf64_size <= 32) {
            buf64_size += 32;
            buf64 |= @as(u64, rdU32be(ptr)) << @intCast(64 - buf64_size);
            ptr += 4;
        }
    }

    // Recursively expand the symbol down to the leaf holding the value.
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
