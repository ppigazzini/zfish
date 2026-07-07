// NNUE refresh cache / finny tables (M17.4f).
//
// The per-(king-square, perspective) AccumulatorRefreshTable: the entry byte
// layout, the typed accessors into each entry (accumulation i16 / psqt i32 /
// pieces / pieceBB), and clearRefreshCache which seeds every entry from the FT
// biases. Split out of nnue_accumulator.zig; pure pointer-offset math over the
// cache blob (std for writeInt), no module deps -- the dimension consts + roundUp
// are duplicated locally. The accumulator core imports this and aliases the
// accessors for its refresh path; clearRefreshCache is pub and re-exported onward
// (called by main.zig / worker_native_construct / engine_trace).

const std = @import("std");

const half_dimensions: usize = 1024;
const psqt_buckets: usize = 8;
const square_count: usize = 64;
const color_count: usize = 2;
const nnue_align: usize = 64;
const feature_transformer_biases_bytes = half_dimensions * @sizeOf(i16);

fn roundUp(value: usize, alignment: usize) usize {
    return ((value + alignment - 1) / alignment) * alignment;
}

const cache_entry_psqt_offset = half_dimensions * @sizeOf(i16);
const cache_entry_pieces_offset = cache_entry_psqt_offset + psqt_buckets * @sizeOf(i32);
const cache_entry_piece_bb_offset = cache_entry_pieces_offset + square_count * @sizeOf(u8);
const cache_entry_bytes = roundUp(cache_entry_piece_bb_offset + @sizeOf(u64), nnue_align);

pub fn cacheEntry(cache: *anyopaque, king_square: u8, perspective: u8) *anyopaque {
    return @ptrCast(cacheBytesMut(cache) +
        ((@as(usize, king_square) * color_count + @as(usize, perspective)) * cache_entry_bytes));
}

// AccumulatorRefreshTable::clear: initialize every (king_square, perspective)
// refresh entry to the empty board -- accumulation = the feature-transformer
// biases, and the rest of the entry (psqt, pieces, pieceBB) zeroed. Mirrors the
// C++ Entry::clear (accumulation = biases; memset from psqtAccumulation to end).
// The biases pointer is passed in by the caller.
pub fn clearRefreshCache(cache: *anyopaque, biases: [*]const i16) void {
    const biases_bytes: [*]const u8 = @ptrCast(biases);
    var ks: usize = 0;
    while (ks < square_count) : (ks += 1) {
        var p: usize = 0;
        while (p < color_count) : (p += 1) {
            const bytes = cacheEntryBytesMut(cacheEntry(cache, @intCast(ks), @intCast(p)));
            @memcpy(bytes[0..feature_transformer_biases_bytes], biases_bytes[0..feature_transformer_biases_bytes]);
            @memset(bytes[cache_entry_psqt_offset..cache_entry_bytes], 0);
        }
    }
}

fn cacheBytesMut(cache: *anyopaque) [*]u8 {
    return @ptrCast(cache);
}

fn cacheEntryBytesMut(entry: *anyopaque) [*]u8 {
    return @ptrCast(entry);
}

pub fn cacheEntryAccumulationConst(entry: *const anyopaque) []const i16 {
    const ptr: [*]const i16 = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(entry))));
    return ptr[0..half_dimensions];
}

pub fn cacheEntryAccumulationMut(entry: *anyopaque) []i16 {
    const ptr: [*]i16 = @ptrCast(@alignCast(cacheEntryBytesMut(entry)));
    return ptr[0..half_dimensions];
}

pub fn cacheEntryPsqtConst(entry: *const anyopaque) []const i32 {
    const ptr: [*]const i32 = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(entry)) + cache_entry_psqt_offset));
    return ptr[0..psqt_buckets];
}

pub fn cacheEntryPsqtMut(entry: *anyopaque) []i32 {
    const ptr: [*]i32 = @ptrCast(@alignCast(cacheEntryBytesMut(entry) + cache_entry_psqt_offset));
    return ptr[0..psqt_buckets];
}

pub fn cacheEntryPiecesMut(entry: *anyopaque) []u8 {
    return (cacheEntryBytesMut(entry) + cache_entry_pieces_offset)[0..square_count];
}

pub fn setCacheEntryPieceBb(entry: *anyopaque, piece_bb: u64) void {
    const bytes = cacheEntryBytesMut(entry);
    std.mem.writeInt(u64, bytes[cache_entry_piece_bb_offset..][0..@sizeOf(u64)], piece_bb, .little);
}
