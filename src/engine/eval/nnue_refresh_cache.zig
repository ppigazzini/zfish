// Provide the NNUE refresh cache / finny tables.
//
// Model the per-(king-square, perspective) AccumulatorRefreshTable: the entry byte
// layout, the typed accessors into each entry (accumulation i16 / psqt i32 /
// pieces), and clearRefreshCache which seeds every entry from the FT
// biases. Split out of nnue_accumulator.zig; pure pointer-offset math over the
// cache blob, no module deps -- the dimension consts + roundUp
// are duplicated locally. The accumulator core imports this and aliases the
// accessors for its refresh path; clearRefreshCache is pub and re-exported onward
// (called by main.zig / worker_construct / engine_trace).

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
// Store only the cached PIECE ARRAY, not a redundant occupancy bitboard: the
// per-square refresh diff reads `entry_pieces[sq]` for exactly the "was a piece
// here" test upstream derives from `changedBB & entry.pieceBB`, so a stored
// bitboard would be written and never read. The entry size is unchanged (the 8
// bytes fall inside the 64-byte round-up).
const cache_entry_bytes = roundUp(cache_entry_pieces_offset + square_count * @sizeOf(u8), nnue_align);

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

// Clear the AccumulatorRefreshTable: initialize every (king_square, perspective)
// refresh entry to the empty board -- accumulation = the feature-transformer
// biases, and the rest of the entry (psqt, pieces) zeroed.
// The biases pointer is passed in by the caller.
pub fn clearRefreshCache(cache: *RefreshCache, biases: [*]const i16) void {
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

pub fn cacheEntryPsqtConst(entry: *const CacheEntry) []const i32 {
    const ptr: [*]const i32 = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(entry)) + cache_entry_psqt_offset));
    return ptr[0..psqt_buckets];
}

pub fn cacheEntryPsqtMut(entry: *CacheEntry) []i32 {
    const ptr: [*]i32 = @ptrCast(@alignCast(cacheEntryBytesMut(entry) + cache_entry_psqt_offset));
    return ptr[0..psqt_buckets];
}

pub fn cacheEntryPiecesMut(entry: *CacheEntry) []u8 {
    return (cacheEntryBytesMut(entry) + cache_entry_pieces_offset)[0..square_count];
}

test {
    @import("std").testing.refAllDecls(@This());
}
