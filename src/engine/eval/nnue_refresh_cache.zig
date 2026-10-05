// Provide the NNUE refresh cache / finny tables.
//
// Model the per-(king-square, perspective) AccumulatorRefreshTable: the entry byte
// layout, the typed accessors into each entry (accumulation i16 / pieces /
// pieceBB), and clearRefreshCache which seeds every entry from the FT
// biases. Split out of nnue_accumulator.zig; pure pointer-offset math over the
// cache blob, no module deps -- the dimension consts + roundUp
// are duplicated locally. The accumulator core imports this and aliases the
// accessors for its refresh path; clearRefreshCache is pub and re-exported onward
// (called by main.zig / worker_construct / engine_trace).

const half_dimensions: usize = 1024;
const square_count: usize = 64;
const color_count: usize = 2;
const nnue_align: usize = 64;
const feature_transformer_biases_bytes = half_dimensions * @sizeOf(i16);

fn roundUp(value: usize, alignment: usize) usize {
    return @divCeil(value, alignment) * alignment;
}

const cache_entry_pieces_offset = half_dimensions * @sizeOf(i16);
/// Store the cached board's occupancy bitboard next to the piece array: the vector
/// refresh diff splits its changed-square bitboard into removed/added via
/// `changedBB & entry.pieceBB` / `changedBB & pos.pieces()` (upstream's shape), so
/// the occupancy must persist with the pieces it describes. Those 8 bytes cost the entry
/// a cache line: accumulation plus pieces is 2112 B, already line-aligned, so the entry is
/// 2176 B -- the size upstream's alignas(CacheLineSize) Entry has for the same three fields.
const cache_entry_piece_bb_offset = cache_entry_pieces_offset + square_count * @sizeOf(u8);
const cache_entry_bytes = roundUp(cache_entry_piece_bb_offset + @sizeOf(u64), nnue_align);
/// The whole table: one entry per (king square, perspective). The Worker embeds a buffer of
/// exactly this many bytes; search_id comptime-asserts worker_layout's pins against it.
pub const table_bytes = cache_entry_bytes * square_count * color_count;

/// Expose opaque handles. The refresh cache is a raw byte arena (the
/// per-(king-square,perspective) finny table); its entries are byte slots within it.
/// Distinct handle types so the eval can't confuse a cache with a stack/FT handle,
/// while the accessors below reinterpret to bytes exactly as before.
pub const RefreshCache = opaque {};
pub const CacheEntry = opaque {};

pub fn cacheEntry(cache: *RefreshCache, king_square: u8, perspective: u8) *CacheEntry {
    return @ptrCast(cacheBytesMut(cache) +
        ((@as(usize, king_square) * color_count + @as(usize, perspective)) * cache_entry_bytes));
}

/// Clear the AccumulatorRefreshTable: initialize every (king_square, perspective)
/// refresh entry to the empty board -- accumulation = the feature-transformer
/// biases, and the rest of the entry (pieces, pieceBB) zeroed.
/// The biases pointer is passed in by the caller.
pub fn clearRefreshCache(cache: *RefreshCache, biases: [*]const i16) void {
    const biases_bytes: [*]const u8 = @ptrCast(biases);
    for (0..square_count) |ks| {
        for (0..color_count) |p| {
            const bytes = cacheEntryBytesMut(cacheEntry(cache, @intCast(ks), @intCast(p)));
            @memcpy(bytes[0..feature_transformer_biases_bytes], biases_bytes[0..feature_transformer_biases_bytes]);
            @memset(bytes[cache_entry_pieces_offset..cache_entry_bytes], 0);
        }
    }
}

fn cacheBytesMut(cache: *RefreshCache) [*]u8 {
    return @ptrCast(cache);
}

fn cacheEntryBytesMut(entry: *CacheEntry) [*]u8 {
    return @ptrCast(entry);
}

pub fn cacheEntryAccumulationConst(entry: *const CacheEntry) []const i16 {
    const ptr: [*]const i16 = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(entry))));
    return ptr[0..half_dimensions];
}

pub fn cacheEntryAccumulationMut(entry: *CacheEntry) []i16 {
    const ptr: [*]i16 = @ptrCast(@alignCast(cacheEntryBytesMut(entry)));
    return ptr[0..half_dimensions];
}

pub fn cacheEntryPiecesMut(entry: *CacheEntry) []u8 {
    return (cacheEntryBytesMut(entry) + cache_entry_pieces_offset)[0..square_count];
}

/// Read/write the cached occupancy through byte-array bitcasts so the module stays
/// std-free and no alignment is assumed; both sides use the same native byte order.
pub fn cacheEntryPieceBb(entry: *const CacheEntry) u64 {
    return @bitCast((@as([*]const u8, @ptrCast(entry)) + cache_entry_piece_bb_offset)[0..8].*);
}

pub fn setCacheEntryPieceBb(entry: *CacheEntry, piece_bb: u64) void {
    (cacheEntryBytesMut(entry) + cache_entry_piece_bb_offset)[0..8].* = @as([8]u8, @bitCast(piece_bb));
}

test {
    @import("std").testing.refAllDecls(@This());
}
