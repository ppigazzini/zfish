//! Register Syzygy tables. Own the material-key -> TBTable map (built at init from the same
//! enumeration as file discovery, tables.zig), the TBTable record itself, and the arena every
//! table's bytes are allocated from. Everything a `.rtbw`/`.rtbz` SAYS -- the load, the magic, the
//! per-(side, file) PairsData parse -- is table_load.zig, which imports this file downward. Keep
//! the probe *algorithm* (do_probe_table, the WDL/DTZ search recursion) in the layer above, in
//! wdl.zig, which imports both; so no file here is a god-file.
//!
//! Compute keys directly from per-color piece counts via the engine's `computeMaterialKey`, so
//! a registry key is bit-identical to the `pos.st.material_key` a probed position carries. Nothing
//! this file records comes from a file: it is derived from the material configuration alone, which
//! is what makes it the reference table_load.zig validates a parsed header against.

const std = @import("std");
const builtin = @import("builtin");

const probe = @import("probe.zig");
const encode = @import("encode.zig");
const position = @import("position");
const board_core = @import("board_core");

const PairsData = probe.PairsData;
const EntryInfo = probe.EntryInfo;

// SF PieceType encodings (via board_core): W pawn=1..king=6, B pawn=9..king=14.
const pawn_pt = board_core.pawn_pt;
const king_pt = board_core.king_pt;

// The file half (table_load.zig) reads these: it opens the files this registry named.
pub const wdl_magic = [4]u8{ 0x71, 0xE8, 0x23, 0x5D };
pub const dtz_magic = [4]u8{ 0xD7, 0x66, 0x0C, 0xA5 };
pub const sep_char: u8 = if (builtin.os.tag == .windows) ';' else ':';

// ---- TBTable + registry -----------------------------------------------------

pub const TBTable = struct {
    key: u64,
    key2: u64,
    piece_count: i32,
    has_pawns: bool,
    has_unique_pieces: bool,
    pawn_count: [2]u8,
    // Colour whose pawns lead the encoding (SF's `c` in the TBTable ctor), 0 = white. Only
    // meaningful when has_pawns; `set` checks the file's own leading piece against it.
    lead_color: u8,
    sides: usize, // WDL: keep 2 when key != key2, else 1. Treat DTZ as always one-sided (1 side).
    stem: [8]u8 = @splat(0), // canonical file stem, e.g. "KQvK"
    stem_len: usize = 0,
    // WDL (.rtbw): two sides x up to four files.
    ready: bool = false,
    base: ?[]const u8 = null, // whole .rtbw bytes (64-aligned base), null if load failed
    items: [2][4]PairsData = @splat(@splat(.{})),
    // DTZ (.rtbz): one side x up to four files, plus the value-remap table base.
    dtz_ready: bool = false,
    dtz_base: ?[]const u8 = null,
    dtz_map: []const u8 = &.{}, // set_dtz_map: the DTZ value maps, bounded by the file
    dtz_items: [1][4]PairsData = @splat(@splat(.{})),

    pub fn info(self: *const TBTable) EntryInfo {
        return .{
            .has_pawns = self.has_pawns,
            .has_unique_pieces = self.has_unique_pieces,
            .piece_count = self.piece_count,
            .pawn_count = self.pawn_count,
        };
    }

    // Port SF entry->get(stm, f): WDL uses items[stm % sides][f], DTZ is one-sided (items[0][f]).
    // Take the file as a TbFile so it cannot arrive transposed with `stm`, which sat beside it
    // as a second bare usize; a pawnless table has one sub-table, so fold every file onto it.
    pub fn get(self: *TBTable, comptime dtz: bool, stm: usize, f: encode.TbFile) *PairsData {
        const file = if (self.has_pawns) f.index() else 0;
        if (dtz) return &self.dtz_items[0][file];
        return &self.items[stm % self.sides][file];
    }
};

const hash_size = 1 << 12; // 4K, indexed by key's low bits (SF TBTables::Size)
const hash_mask = hash_size - 1;

var arena_state: ?std.heap.ArenaAllocator = null;
var tables: std.ArrayList(*TBTable) = .empty;
var hash_keys: [hash_size]u64 = @splat(0);
var hash_tabs: [hash_size]?*TBTable = @splat(null);
var reg_path: []const u8 = "";
var geometry_ready = false;

/// Hand out the registry arena. Every table's file bytes and its owned symbol tables live here,
/// so a `reset` for a new SyzygyPath frees them all at once.
pub fn arena() std.mem.Allocator {
    return arena_state.?.allocator();
}

/// Report the SyzygyPath the registry was built for, separator-joined as the user gave it.
pub fn searchPath() []const u8 {
    return reg_path;
}

/// Report true once a SyzygyPath has been set (so the probe surface can early-out when unconfigured).
pub fn ready() bool {
    return arena_state != null;
}

/// (Re)build the registry for a new SyzygyPath. Called by tables.init before enumeration.
/// `path` must outlive the registry (tables.zig keeps it in a static buffer).
pub fn reset(path: []const u8) void {
    if (arena_state) |*a| a.deinit();
    arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    tables = .empty;
    @memset(&hash_keys, 0);
    @memset(&hash_tabs, null);
    reg_path = path;
    if (!geometry_ready) {
        encode.initGeometry();
        geometry_ready = true;
    }
}

fn hashInsert(key: u64, t: *TBTable) void {
    var i: usize = @as(usize, @intCast(key)) & hash_mask;
    while (hash_tabs[i] != null) : (i = (i + 1) & hash_mask) {}
    hash_keys[i] = key;
    hash_tabs[i] = t;
}

pub fn hashGet(key: u64) ?*TBTable {
    var i: usize = @as(usize, @intCast(key)) & hash_mask;
    while (hash_tabs[i]) |t| : (i = (i + 1) & hash_mask) {
        if (hash_keys[i] == key) return t;
    }
    return null;
}

/// Register a found WDL table for `pieces` (e.g. {K,Q,K}). Compute both material keys, the
/// pawn/unique-piece flags SF derives from a code-Position, and insert under key and key2.
/// Called by tables.add when the `.rtbw` file exists.
pub fn register(pieces: []const u8) void {
    // Split the code at the second king: white (strong) = [0, k2), black (weak) = [k2, len).
    var k2: usize = 1;
    while (k2 < pieces.len and pieces[k2] != king_pt) k2 += 1;

    var counts: [16]i32 = @splat(0);
    for (pieces[0..k2]) |pt| counts[pt] += 1; // white byte = pt
    for (pieces[k2..]) |pt| counts[@as(usize, pt) | 8] += 1; // black byte = 8|pt

    const key = position.computeMaterialKey(&counts, 16);
    var counts2: [16]i32 = @splat(0);
    for (0..16) |i| counts2[i ^ 8] = counts[i]; // color-swap
    const key2 = position.computeMaterialKey(&counts2, 16);

    const wp = counts[pawn_pt];
    const bp = counts[@as(usize, pawn_pt) | 8];
    const has_pawns = wp != 0 or bp != 0;
    var has_unique = false;
    var pt: usize = pawn_pt;
    while (pt < king_pt) : (pt += 1) {
        if (counts[pt] == 1 or counts[pt | 8] == 1) has_unique = true;
    }

    // Pick the leading color: WHITE unless both sides have pawns and black has fewer (better compression).
    const lead_white = (bp == 0) or (wp != 0 and bp >= wp);
    const t = arena().create(TBTable) catch return;
    t.* = .{
        .key = key,
        .key2 = key2,
        .piece_count = @intCast(pieces.len),
        .has_pawns = has_pawns,
        .has_unique_pieces = has_unique,
        .pawn_count = .{
            @intCast(if (lead_white) wp else bp),
            @intCast(if (lead_white) bp else wp),
        },
        .lead_color = if (lead_white) 0 else 1,
        .sides = if (key != key2) 2 else 1,
    };
    buildStem(pieces, t);
    tables.append(arena(), t) catch return;
    hashInsert(key, t);
    if (key2 != key) hashInsert(key2, t);
}

// Build the canonical stem: PieceToChar per piece, insert 'v' before the second 'K'.
fn buildStem(pieces: []const u8, t: *TBTable) void {
    const piece_char = " PNBRQK";
    var n: usize = 0;
    for (pieces) |pt| {
        t.stem[n] = piece_char[pt];
        n += 1;
    }
    var k: usize = 1;
    while (k < n and t.stem[k] != 'K') k += 1;
    var j: usize = n;
    while (j > k) : (j -= 1) t.stem[j] = t.stem[j - 1];
    t.stem[k] = 'v';
    t.stem_len = n + 1;
}

test {
    std.testing.refAllDecls(@This());
}
