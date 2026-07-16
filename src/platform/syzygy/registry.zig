//! Register Syzygy tables and manage their files. Own the material-key -> TBTable map (built at init from
//! the same enumeration as file discovery, tables.zig), the lazy `.rtbw`/`.rtbz` file load into a
//! 64-byte-aligned buffer, and Stockfish's `set`/`set_dtz_map` that parse a mapped file's
//! per-(side,file) PairsData records. Keep the probe *algorithm* (do_probe_table, the WDL/DTZ search
//! recursion) in the layer above, in wdl.zig, which imports this one -- a single downward dependency
//! (registry knows nothing of the algorithm), so neither file is a god-file.
//!
//! Compute keys directly from per-color piece counts via the engine's `computeMaterialKey`, so
//! a registry key is bit-identical to the `pos.st.material_key` a probed position carries. Read file
//! bytes via libc (no `Io` at the probe seam); the 64-alignment makes the data-section
//! rounding in `set` match an mmap base. Load files POSIX-only; a Windows CreateFileMapping path is
//! not yet implemented, so on Windows the load yields null and the probe reports "unavailable".

const std = @import("std");
const builtin = @import("builtin");

const probe = @import("probe.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const position = @import("position");
const board_core = @import("board_core");

const PairsData = probe.PairsData;
const EntryInfo = probe.EntryInfo;

// SF PieceType encodings (via board_core): W pawn=1..king=6, B pawn=9..king=14.
const pawn_pt = board_core.pawn_pt;
const king_pt = board_core.king_pt;

const wdl_magic = [4]u8{ 0x71, 0xE8, 0x23, 0x5D };
const dtz_magic = [4]u8{ 0xD7, 0x66, 0x0C, 0xA5 };
const sep_char: u8 = if (builtin.os.tag == .windows) ';' else ':';

// ---- TBTable + registry -----------------------------------------------------

pub const TBTable = struct {
    key: u64,
    key2: u64,
    piece_count: i32,
    has_pawns: bool,
    has_unique_pieces: bool,
    pawn_count: [2]u8,
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
    dtz_map: ?[*]const u8 = null, // set_dtz_map: base of the DTZ value maps
    dtz_items: [1][4]PairsData = @splat(@splat(.{})),

    fn info(self: *const TBTable) EntryInfo {
        return .{
            .has_pawns = self.has_pawns,
            .has_unique_pieces = self.has_unique_pieces,
            .piece_count = self.piece_count,
            .pawn_count = self.pawn_count,
        };
    }

    // Port SF entry->get(stm, f): WDL uses items[stm % sides][f], DTZ is one-sided (items[0][f]).
    pub fn get(self: *TBTable, comptime dtz: bool, stm: usize, f: usize) *PairsData {
        const file = if (self.has_pawns) f else 0;
        if (dtz) return &self.dtz_items[0][file];
        return &self.items[stm % self.sides][file];
    }
};

const hash_size = 1 << 12; // 4K, indexed by key's low bits (SF TBTables::Size)
const hash_mask = hash_size - 1;

var arena_state: ?std.heap.ArenaAllocator = null;
var tables: std.ArrayListUnmanaged(*TBTable) = .empty;
var hash_keys: [hash_size]u64 = @splat(0);
var hash_tabs: [hash_size]?*TBTable = @splat(null);
var reg_path: []const u8 = "";
var geometry_ready = false;

fn arena() std.mem.Allocator {
    return arena_state.?.allocator();
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

    var counts: [16]c_int = @splat(0);
    for (pieces[0..k2]) |pt| counts[pt] += 1; // white byte = pt
    for (pieces[k2..]) |pt| counts[@as(usize, pt) | 8] += 1; // black byte = 8|pt

    const key = position.computeMaterialKey(&counts, 16);
    var counts2: [16]c_int = @splat(0);
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

// ---- file load (64-aligned buffer, libc, Linux-gated) -----------------------

// Read <stem><ext> from the first SyzygyPath dir that has it into a 64-byte-aligned buffer,
// verifying `magic`. Return the whole file (magic included) or null on any failure. The
// 64-alignment makes the data-section rounding in `set` match an mmap base. POSIX only (libc
// open/read); Windows file mapping (a distinct CreateFileMapping path) is not yet implemented, so on
// Windows this yields null and the probe reports "unavailable" -- the graceful missing-file path.
fn loadFile(t: *TBTable, ext: []const u8, magic: [4]u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;

    var it = std.mem.splitScalar(u8, reg_path, sep_char);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var zbuf: [4097]u8 = undefined;
        const full = std.fmt.bufPrint(&zbuf, "{s}/{s}{s}\x00", .{ dir, t.stem[0..t.stem_len], ext }) catch continue;
        const z: [*:0]const u8 = @ptrCast(full.ptr);
        const fd = std.c.open(z, .{ .ACCMODE = .RDONLY });
        if (fd < 0) continue;
        defer _ = std.c.close(fd);

        // Read the whole file (glibc has no plain `fstat` symbol, so grow a buffer to EOF).
        var acc: std.ArrayListUnmanaged(u8) = .empty;
        var chunk: [1 << 16]u8 = undefined;
        while (true) {
            const r = std.c.read(fd, &chunk, chunk.len);
            if (r < 0) break;
            if (r == 0) {
                const size = acc.items.len;
                if (size < 4 or size % 64 != 16) break; // SF corruption check
                // Over-allocate + hand-align to 64 so base % 64 == 0 (mmap-equivalent).
                const raw = arena().alloc(u8, size + 63) catch return null;
                const off = (64 - (@intFromPtr(raw.ptr) & 63)) & 63;
                const buf = raw[off .. off + size];
                @memcpy(buf, acc.items);
                if (!std.mem.eql(u8, buf[0..4], &magic)) break;
                return buf;
            }
            acc.appendSlice(arena(), chunk[0..@intCast(r)]) catch return null;
        }
    }
    return null;
}

// ---- set: parse the file's PairsData records (SF `set`) ---------------------

// Port SF `set`, generic over WDL/DTZ. `buf` is the whole file (64-aligned base); parsing starts at
// offset 4 (after the magic). Fill every (side,file) PairsData. For DTZ, `set_dtz_map` reads the
// value-remap table between the size headers and the sparse indices.
fn set(t: *TBTable, comptime dtz: bool, buf: []const u8) void {
    const e = t.info();
    var pos: usize = 4; // skip magic
    // Skip the first byte after magic: Split(1)/HasPawns(2) flags (asserted in SF; we trust the file).
    pos += 1;

    // Treat DTZ tables as one-sided; WDL split tables (key != key2) store both sides.
    const sides: usize = if (dtz) 1 else t.sides;
    const max_file: usize = if (t.has_pawns) 3 else 0; // FILE_D or FILE_A
    const pp = t.has_pawns and t.pawn_count[1] != 0;

    var f: usize = 0;
    while (f <= max_file) : (f += 1) {
        var i: usize = 0;
        while (i < sides) : (i += 1) t.get(dtz, i, f).* = .{};

        var order: [2][2]i32 = undefined;
        order[0][0] = @intCast(buf[pos] & 0xF);
        order[0][1] = if (pp) @intCast(buf[pos + 1] & 0xF) else 0xF;
        order[1][0] = @intCast(buf[pos] >> 4);
        order[1][1] = if (pp) @intCast(buf[pos + 1] >> 4) else 0xF;
        pos += @as(usize, 1) + @intFromBool(pp);

        var k: usize = 0;
        while (k < @as(usize, @intCast(t.piece_count))) : (k += 1) {
            i = 0;
            while (i < sides) : (i += 1) {
                t.get(dtz, i, f).pieces[k] = if (i != 0) buf[pos] >> 4 else buf[pos] & 0xF;
            }
            pos += 1;
        }
        i = 0;
        while (i < sides) : (i += 1) {
            probe.setGroups(t.get(dtz, i, f), e, order[i], f);
        }
    }

    pos += pos & 1; // word alignment (base is 64-aligned, so pos parity == address parity)

    f = 0;
    while (f <= max_file) : (f += 1) {
        var i: usize = 0;
        while (i < sides) : (i += 1) {
            decode.setSizes(arena(), t.get(dtz, i, f), buf, &pos) catch return;
        }
    }

    if (dtz) setDtzMap(t, buf, &pos, max_file);

    f = 0;
    while (f <= max_file) : (f += 1) {
        var i: usize = 0;
        while (i < sides) : (i += 1) {
            const d = t.get(dtz, i, f);
            d.sparse_index = buf[pos..].ptr;
            pos += d.sparse_index_size * @sizeOf(probe.SparseEntry);
        }
    }
    f = 0;
    while (f <= max_file) : (f += 1) {
        var i: usize = 0;
        while (i < sides) : (i += 1) {
            const d = t.get(dtz, i, f);
            d.block_length = buf[pos..].ptr;
            pos += @as(usize, d.block_length_size) * 2;
        }
    }
    f = 0;
    while (f <= max_file) : (f += 1) {
        var i: usize = 0;
        while (i < sides) : (i += 1) {
            pos = (pos + 0x3F) & ~@as(usize, 0x3F); // 64-byte alignment
            const d = t.get(dtz, i, f);
            d.data = buf[pos..].ptr;
            pos += @as(usize, d.blocks_num) * d.sizeof_block;
        }
    }
}

// Port SF `set_dtz_map`: read the per-file DTZ value-remap tables. `map_idx[i]` records the offset of
// each of the four WDL-class maps from `dtz_map` (u16 units when Wide, bytes otherwise, +1 as SF).
fn setDtzMap(t: *TBTable, buf: []const u8, pos: *usize, max_file: usize) void {
    t.dtz_map = buf[pos.*..].ptr;
    const map_base = pos.*;
    var f: usize = 0;
    while (f <= max_file) : (f += 1) {
        const d = t.get(true, 0, f);
        if (d.flags & decode.flag_mapped != 0) {
            if (d.flags & decode.flag_wide != 0) {
                pos.* += pos.* & 1; // word align
                var i: usize = 0;
                while (i < 4) : (i += 1) {
                    d.map_idx[i] = @intCast((pos.* - map_base) / 2 + 1);
                    pos.* += 2 * @as(usize, rdU16(buf[pos.*..].ptr)) + 2;
                }
            } else {
                var i: usize = 0;
                while (i < 4) : (i += 1) {
                    d.map_idx[i] = @intCast(pos.* - map_base + 1);
                    pos.* += @as(usize, buf[pos.*]) + 1;
                }
            }
        }
    }
    pos.* += pos.* & 1; // word align
}

pub inline fn rdU16(p: [*]const u8) u16 {
    return std.mem.readInt(u16, @ptrCast(p), .little);
}

// Load + parse lazily on first probe. Return true if the WDL table is usable.
pub fn mapped(t: *TBTable) bool {
    if (t.ready) return t.base != null;
    t.ready = true;
    const buf = loadFile(t, ".rtbw", wdl_magic) orelse {
        t.base = null;
        return false;
    };
    t.base = buf;
    set(t, false, buf);
    return true;
}

// Load + parse the DTZ (.rtbz) file lazily on first DTZ probe.
pub fn mappedDtz(t: *TBTable) bool {
    if (t.dtz_ready) return t.dtz_base != null;
    t.dtz_ready = true;
    const buf = loadFile(t, ".rtbz", dtz_magic) orelse {
        t.dtz_base = null;
        return false;
    };
    t.dtz_base = buf;
    set(t, true, buf);
    return true;
}

test {
    std.testing.refAllDecls(@This());
}
