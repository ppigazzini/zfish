//! Syzygy WDL probe orchestration (M-SZ-2c pt2). Faithful port of Stockfish's `do_probe_table`
//! (position -> unique index), `set` (parse the mmapped file's per-(side,file) PairsData records),
//! `mapped` (lazy file load on first probe), and `probe_table<WDL>`. This is the layer that ties
//! together the M-SZ-2a geometry (encode.zig), the M-SZ-2b data model (probe.zig: PairsData,
//! set_groups, set_symlen), and the M-SZ-2c pt1 decoder (decode.zig: set_sizes, decompress_pairs).
//!
//! The table registry (material key -> TBTable) is built at init from the same material
//! configuration enumeration as file discovery (tables.zig `add`). Keys are computed directly from
//! per-color piece counts via the engine's `computeMaterialKey`, so a registry key is bit-identical
//! to the `pos.st.material_key` a probed position carries -- no scratch Position needed to register.
//!
//! Platform->engine down-edge (legal, per REPORT-19): the probe reaches the headless engine for a
//! scratch Position (FEN parse), its material key + piece bitboards, and -- in pt2b -- legal-capture
//! movegen for the capture recursion. File bytes are read into a 64-byte-aligned heap buffer via
//! libc (no `Io` at the probe seam); the data-section alignment math matches an mmap base.
//!
//! WDL only: DTZ (`probe_dtz`, the DTZ map, root ranking) is M-SZ-3. Linux-gated (`tb-wdl`):
//! cross-OS file loading comes with M-SZ-4.

const std = @import("std");
const builtin = @import("builtin");

const probe = @import("probe.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");

const position = @import("position");
const board_core = @import("board_core");
const state_list = @import("state_list");
const movegen = @import("movegen");

const Position = position.Position;
const StateInfo = position.StateInfo;
const PairsData = probe.PairsData;
const EntryInfo = probe.EntryInfo;

const ProbeResult = @import("tb_source").ProbeResult;

// SF PieceType / Color encodings (via board_core): W pawn=1..king=6, B pawn=9..king=14.
const pawn_pt = board_core.pawn_pt;
const king_pt = board_core.king_pt;

const wdl_magic = [4]u8{ 0x71, 0xE8, 0x23, 0x5D };
const dtz_magic = [4]u8{ 0xD7, 0x66, 0x0C, 0xA5 };
const sep_char: u8 = if (builtin.os.tag == .windows) ';' else ':';

// ---- TBTable + registry -----------------------------------------------------

const TBTable = struct {
    key: u64,
    key2: u64,
    piece_count: i32,
    has_pawns: bool,
    has_unique_pieces: bool,
    pawn_count: [2]u8,
    sides: usize, // WDL: 2 when key != key2, else 1. DTZ is always one-sided (1 side).
    stem: [8]u8 = [_]u8{0} ** 8, // canonical file stem, e.g. "KQvK"
    stem_len: usize = 0,
    // WDL (.rtbw): two sides x up to four files.
    ready: bool = false,
    base: ?[]const u8 = null, // whole .rtbw bytes (64-aligned base), null if load failed
    items: [2][4]PairsData = [_][4]PairsData{[_]PairsData{.{}} ** 4} ** 2,
    // DTZ (.rtbz): one side x up to four files, plus the value-remap table base.
    dtz_ready: bool = false,
    dtz_base: ?[]const u8 = null,
    dtz_map: ?[*]const u8 = null, // set_dtz_map: base of the DTZ value maps
    dtz_items: [1][4]PairsData = [_][4]PairsData{[_]PairsData{.{}} ** 4} ** 1,

    fn info(self: *const TBTable) EntryInfo {
        return .{
            .has_pawns = self.has_pawns,
            .has_unique_pieces = self.has_unique_pieces,
            .piece_count = self.piece_count,
            .pawn_count = self.pawn_count,
        };
    }

    // SF entry->get(stm, f): WDL uses items[stm % sides][f], DTZ is one-sided (items[0][f]).
    fn get(self: *TBTable, comptime dtz: bool, stm: usize, f: usize) *PairsData {
        const file = if (self.has_pawns) f else 0;
        if (dtz) return &self.dtz_items[0][file];
        return &self.items[stm % self.sides][file];
    }
};

const hash_size = 1 << 12; // 4K, indexed by key's low bits (SF TBTables::Size)
const hash_mask = hash_size - 1;

var arena_state: ?std.heap.ArenaAllocator = null;
var tables: std.ArrayListUnmanaged(*TBTable) = .empty;
var hash_keys: [hash_size]u64 = [_]u64{0} ** hash_size;
var hash_tabs: [hash_size]?*TBTable = [_]?*TBTable{null} ** hash_size;
var reg_path: []const u8 = "";
var geometry_ready = false;

fn arena() std.mem.Allocator {
    return arena_state.?.allocator();
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

fn hashGet(key: u64) ?*TBTable {
    var i: usize = @as(usize, @intCast(key)) & hash_mask;
    while (hash_tabs[i]) |t| : (i = (i + 1) & hash_mask) {
        if (hash_keys[i] == key) return t;
    }
    return null;
}

/// Register a found WDL table for `pieces` (e.g. {K,Q,K}). Computes both material keys, the
/// pawn/unique-piece flags SF derives from a code-Position, and inserts under key and key2.
/// Called by tables.add when the `.rtbw` file exists.
pub fn register(pieces: []const u8) void {
    // Split the code at the second king: white (strong) = [0, k2), black (weak) = [k2, len).
    var k2: usize = 1;
    while (k2 < pieces.len and pieces[k2] != king_pt) k2 += 1;

    var counts = [_]c_int{0} ** 16;
    for (pieces[0..k2]) |pt| counts[pt] += 1; // white byte = pt
    for (pieces[k2..]) |pt| counts[@as(usize, pt) | 8] += 1; // black byte = 8|pt

    const key = position.computeMaterialKey(&counts, 16);
    var counts2 = [_]c_int{0} ** 16;
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

    // Leading color: WHITE unless both sides have pawns and black has fewer (better compression).
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
// verifying `magic`. Returns the whole file (magic included) or null on any failure. The
// 64-alignment makes the data-section rounding in `set` match an mmap base. POSIX only (libc
// open/read); Windows file mapping (a distinct CreateFileMapping path) comes with M-SZ-4, so on
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

// SF `set`, generic over WDL/DTZ. `buf` is the whole file (64-aligned base); parsing starts at
// offset 4 (after the magic). Fills every (side,file) PairsData. For DTZ, `set_dtz_map` reads the
// value-remap table between the size headers and the sparse indices.
fn set(t: *TBTable, comptime dtz: bool, buf: []const u8) void {
    const e = t.info();
    var pos: usize = 4; // skip magic
    // First byte after magic: Split(1)/HasPawns(2) flags (asserted in SF; we trust the file).
    pos += 1;

    // DTZ tables are one-sided; WDL split tables (key != key2) store both sides.
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

// SF `set_dtz_map`: read the per-file DTZ value-remap tables. `map_idx[i]` records the offset of
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

inline fn rdU16(p: [*]const u8) u16 {
    return std.mem.readInt(u16, @ptrCast(p), .little);
}

// Lazy load + parse on first probe. Returns true if the WDL table is usable.
fn mapped(t: *TBTable) bool {
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

// Lazy load + parse of the DTZ (.rtbz) file on first DTZ probe.
fn mappedDtz(t: *TBTable) bool {
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

// ---- do_probe_table: position -> index -> WDL (SF do_probe_table<WDL>) -------

const tb_pieces = probe.tb_pieces;

inline fn fileOf(sq: u8) usize {
    return sq & 7;
}
inline fn rankOf(sq: u8) usize {
    return sq >> 3;
}
inline fn mapPawns(sq: u8) i32 {
    return encode.map_pawns[sq];
}

// SF do_probe_table, generic over WDL/DTZ. WDL returns the raw score in -2..2 (value - 2); DTZ
// returns map_score<DTZ>(value) given the position's `wdl_score`. For DTZ, if the stored side does
// not match the side to move, sets out_state = CHANGE_STM (the caller does a 1-ply search).
fn doProbeTable(pos: *const Position, t: *TBTable, comptime dtz: bool, wdl_score: i32, out_state: *i32) i32 {
    var squares: [tb_pieces]u8 = undefined;
    var pieces_arr: [tb_pieces]u8 = undefined;
    var size: usize = 0;
    var lead_pawns_cnt: usize = 0;
    var tb_file: usize = 0;

    const material_key = pos.st.material_key;
    const stm_pos: usize = pos.side_to_move;

    const symmetric_btm = (t.key == t.key2) and (stm_pos != 0);
    const black_stronger = material_key != t.key;
    const swap = symmetric_btm or black_stronger;
    const flip_color: u8 = if (swap) 8 else 0;
    const flip_squares: u8 = if (swap) 56 else 0;
    const stm: usize = @intFromBool(swap) ^ stm_pos;

    var lead_pawns: u64 = 0;
    if (t.has_pawns) {
        const pc = t.get(dtz, 0, 0).pieces[0] ^ flip_color;
        const lead_color: usize = pc >> 3;
        lead_pawns = pos.by_color_bb[lead_color] & pos.by_type_bb[pawn_pt];
        var b = lead_pawns;
        while (b != 0) {
            const s: u8 = @intCast(@ctz(b));
            b &= b - 1;
            squares[size] = s ^ flip_squares;
            size += 1;
        }
        lead_pawns_cnt = size;

        // Move the pawn with the maximum MapPawns[] into squares[0] (first max).
        var maxi: usize = 0;
        var mj: usize = 1;
        while (mj < lead_pawns_cnt) : (mj += 1) {
            if (mapPawns(squares[mj]) > mapPawns(squares[maxi])) maxi = mj;
        }
        const tmp = squares[0];
        squares[0] = squares[maxi];
        squares[maxi] = tmp;

        tb_file = encode.edgeDistance(fileOf(squares[0]));
    }

    // DTZ tables are one-sided: if the stored side is not the side to move, bail to a 1-ply
    // search (CHANGE_STM). WDL check_dtz_stm is always true.
    if (dtz) {
        const flags = t.get(true, stm, tb_file).flags;
        const stm_ok = (flags & decode.flag_stm) == stm or (t.key == t.key2 and !t.has_pawns);
        if (!stm_ok) {
            out_state.* = change_stm;
            return 0;
        }
    }

    // Gather the remaining pieces (all except the lead pawns).
    var b = pos.by_type_bb[0] ^ lead_pawns;
    while (b != 0) {
        const s: u8 = @intCast(@ctz(b));
        b &= b - 1;
        squares[size] = s ^ flip_squares;
        pieces_arr[size] = pos.board[s] ^ flip_color;
        size += 1;
    }

    const d = t.get(dtz, stm, tb_file);

    // Reorder pieces to match the file's canonical d.pieces sequence.
    var ri = lead_pawns_cnt;
    while (ri + 1 < size) : (ri += 1) {
        var rj = ri + 1;
        while (rj < size) : (rj += 1) {
            if (d.pieces[ri] == pieces_arr[rj]) {
                const ps = pieces_arr[ri];
                pieces_arr[ri] = pieces_arr[rj];
                pieces_arr[rj] = ps;
                const sq = squares[ri];
                squares[ri] = squares[rj];
                squares[rj] = sq;
                break;
            }
        }
    }

    // Map the lead square into the a1-d1-d4 triangle (file <= D).
    if (fileOf(squares[0]) > 3) {
        for (0..size) |i| squares[i] ^= 7;
    }

    var idx: u64 = 0;
    if (t.has_pawns) {
        idx = @intCast(encode.lead_pawn_idx[lead_pawns_cnt][squares[0]]);
        stableSortByMapPawns(squares[1..lead_pawns_cnt]);
        var i: usize = 1;
        while (i < lead_pawns_cnt) : (i += 1) {
            idx += @intCast(encode.binomial[i][@intCast(mapPawns(squares[i]))]);
        }
    } else {
        // Flip so the leading piece is below RANK_5.
        if (rankOf(squares[0]) > 3) {
            for (0..size) |i| squares[i] ^= 56;
        }
        // First leading-group piece off the a1-h8 diagonal -> map below it.
        var i: usize = 0;
        while (i < @as(usize, @intCast(d.group_len[0]))) : (i += 1) {
            if (encode.offA1H8(squares[i]) == 0) continue;
            if (encode.offA1H8(squares[i]) > 0) {
                var j = i;
                while (j < size) : (j += 1) {
                    const sq: u16 = squares[j];
                    squares[j] = @intCast(((sq >> 3) | (sq << 3)) & 63);
                }
            }
            break;
        }

        if (t.has_unique_pieces) {
            const adjust1: i64 = @intFromBool(squares[1] > squares[0]);
            const adjust2: i64 = @as(i64, @intFromBool(squares[2] > squares[0])) +
                @intFromBool(squares[2] > squares[1]);
            const s1: i64 = squares[1];
            const s2: i64 = squares[2];
            if (encode.offA1H8(squares[0]) != 0) {
                idx = @intCast((@as(i64, encode.map_a1d1d4[squares[0]]) * 63 + (s1 - adjust1)) * 62 + s2 - adjust2);
            } else if (encode.offA1H8(squares[1]) != 0) {
                idx = @intCast((6 * 63 + @as(i64, @intCast(rankOf(squares[0]))) * 28 + encode.map_b1h1h7[squares[1]]) * 62 + s2 - adjust2);
            } else if (encode.offA1H8(squares[2]) != 0) {
                idx = @intCast(6 * 63 * 62 + 4 * 28 * 62 + @as(i64, @intCast(rankOf(squares[0]))) * 7 * 28 +
                    (@as(i64, @intCast(rankOf(squares[1]))) - adjust1) * 28 + encode.map_b1h1h7[squares[2]]);
            } else {
                idx = @intCast(6 * 63 * 62 + 4 * 28 * 62 + 4 * 7 * 28 + @as(i64, @intCast(rankOf(squares[0]))) * 7 * 6 +
                    (@as(i64, @intCast(rankOf(squares[1]))) - adjust1) * 6 + (@as(i64, @intCast(rankOf(squares[2]))) - adjust2));
            }
        } else {
            idx = @intCast(encode.map_kk[@intCast(encode.map_a1d1d4[squares[0]])][squares[1]]);
        }
    }

    idx *= d.group_idx[0];

    // Encode remaining groups.
    var group_off: usize = @intCast(d.group_len[0]);
    var remaining_pawns = t.has_pawns and t.pawn_count[1] != 0;
    var next: usize = 0;
    while (true) {
        next += 1;
        const glen: usize = @intCast(d.group_len[next]);
        if (glen == 0) break;
        stableSortSquares(squares[group_off .. group_off + glen]);
        var n: u64 = 0;
        var gi: usize = 0;
        while (gi < glen) : (gi += 1) {
            var adjust: i64 = 0;
            var si: usize = 0;
            while (si < group_off) : (si += 1) {
                adjust += @intFromBool(squares[group_off + gi] > squares[si]);
            }
            const col: i64 = @as(i64, squares[group_off + gi]) - adjust - (if (remaining_pawns) @as(i64, 8) else 0);
            n += @intCast(encode.binomial[gi + 1][@intCast(col)]);
        }
        remaining_pawns = false;
        idx += n * d.group_idx[next];
        group_off += glen;
    }

    const raw = decode.decompressPairs(d, idx);
    if (dtz) return mapScoreDtz(t, d, raw, wdl_score);
    return raw - 2; // map_score<WDL> = value - 2
}

// SF map_score<DTZ>: remap the raw DTZ value through the per-WDL-class map, then convert to plies
// (x2 unless the flags already store plies for this class) and +1.
fn mapScoreDtz(t: *TBTable, d: *const PairsData, value_in: i32, wdl: i32) i32 {
    const wdl_map = [_]usize{ 1, 3, 0, 2, 0 }; // index by wdl+2
    var value = value_in;
    const flags = d.flags;
    if (flags & decode.flag_mapped != 0) {
        const mi: usize = d.map_idx[wdl_map[@intCast(wdl + 2)]];
        const off = mi + @as(usize, @intCast(value));
        if (flags & decode.flag_wide != 0) {
            value = rdU16(t.dtz_map.? + off * 2);
        } else {
            value = t.dtz_map.?[off];
        }
    }
    if ((wdl == wdl_win and flags & decode.flag_win_plies == 0) or
        (wdl == wdl_loss and flags & decode.flag_loss_plies == 0) or
        wdl == wdl_cursed_win or wdl == wdl_blessed_loss)
    {
        value *= 2;
    }
    return value + 1;
}

inline fn stableSortByMapPawns(sq: []u8) void {
    // Insertion sort (stable), ascending MapPawns[].
    var i: usize = 1;
    while (i < sq.len) : (i += 1) {
        const v = sq[i];
        var j = i;
        while (j > 0 and mapPawns(sq[j - 1]) > mapPawns(v)) : (j -= 1) sq[j] = sq[j - 1];
        sq[j] = v;
    }
}

inline fn stableSortSquares(sq: []u8) void {
    var i: usize = 1;
    while (i < sq.len) : (i += 1) {
        const v = sq[i];
        var j = i;
        while (j > 0 and sq[j - 1] > v) : (j -= 1) sq[j] = sq[j - 1];
        sq[j] = v;
    }
}

// ---- probe_table + probe_wdl (search) + probe_dtz ---------------------------

// SF ProbeState: FAIL=0, OK=1, ZEROING_BEST_MOVE=2, CHANGE_STM=-1.
const probe_fail: i32 = 0;
const probe_ok: i32 = 1;
const probe_zeroing: i32 = 2;
const change_stm: i32 = -1;
// SF WDLScore.
const wdl_win: i32 = 2;
const wdl_cursed_win: i32 = 1;
const wdl_draw: i32 = 0;
const wdl_blessed_loss: i32 = -1;
const wdl_loss: i32 = -2;

const Probe = struct { value: i32, state: i32 };

// SF probe_table, generic over WDL/DTZ: KvK short-circuit, registry lookup, lazy map, do_probe.
fn probeTable(pos: *const Position, comptime dtz: bool, wdl_score: i32, out_state: *i32) i32 {
    if (@popCount(pos.by_type_bb[0]) == 2) return 0; // KvK draw
    const t = hashGet(pos.st.material_key) orelse {
        out_state.* = probe_fail;
        return 0;
    };
    const ok = if (dtz) mappedDtz(t) else mapped(t);
    if (!ok) {
        out_state.* = probe_fail;
        return 0;
    }
    return doProbeTable(pos, t, dtz, wdl_score, out_state);
}

fn isCapture(pos: *const Position, m: u16) bool {
    const to = board_core.moveTo(m);
    const mt = board_core.moveTypeOf(m);
    return (pos.board[to] != 0 and mt != board_core.mt_castling) or mt == board_core.mt_en_passant;
}

inline fn movedPieceType(pos: *const Position, m: u16) u8 {
    return pos.board[board_core.moveFrom(m)] & 7;
}

fn signOf(x: i32) i32 {
    return @as(i32, @intFromBool(x > 0)) - @intFromBool(x < 0);
}

// SF dtz_before_zeroing: recover the DTZ of the move before a zeroing (capture/pawn) move.
fn dtzBeforeZeroing(wdl: i32) i32 {
    return switch (wdl) {
        wdl_win => 1,
        wdl_cursed_win => 101,
        wdl_blessed_loss => -101,
        wdl_loss => -1,
        else => 0,
    };
}

// SF search<CheckZeroingMoves>: the "best of the position and its winning/drawing zeroing moves"
// recursion. A capture (and, when check_zeroing, a pawn move) zeroes the rule50 counter, so its
// result must be probed and compared to the position's own stored value. Children recurse with
// check_zeroing=false. `storage` supplies one StateInfo per recursion frame (reused across sibs).
fn searchWdl(pos: *Position, storage: *state_list.PendingStateStorage, comptime check_zeroing: bool) Probe {
    var best: i32 = wdl_loss;
    var move_count: usize = 0;
    var buf: [256]u16 = undefined;
    const total = movegen.generateLegal(pos, buf[0..].ptr);

    const st = state_list.storagePush(storage) catch return .{ .value = 0, .state = probe_fail };

    var i: usize = 0;
    while (i < total) : (i += 1) {
        const m = buf[i];
        if (!isCapture(pos, m) and (!check_zeroing or movedPieceType(pos, m) != pawn_pt)) continue;
        move_count += 1;
        position.doMoveState(pos, m, st);
        const child = searchWdl(pos, storage, false);
        position.undoMove(pos, m);
        if (child.state == probe_fail) return .{ .value = 0, .state = probe_fail };
        const v = -child.value;
        if (v > best) {
            best = v;
            if (v >= wdl_win) return .{ .value = v, .state = probe_zeroing }; // winning zeroing move
        }
    }

    // If every legal move is a zeroing move and we searched them all, the stored value could be
    // wrong (ep rights, all-captures) -- use bestValue instead of probing.
    const no_more_moves = move_count != 0 and move_count == total;
    var value: i32 = undefined;
    if (no_more_moves) {
        value = best;
    } else {
        var st_probe: i32 = probe_ok;
        value = probeTable(pos, false, 0, &st_probe);
        if (st_probe == probe_fail) return .{ .value = 0, .state = probe_fail };
    }

    // DTZ stores a "don't care" when bestValue is a win: prefer bestValue when it dominates.
    if (best >= value) {
        const state: i32 = if (best > 0 or no_more_moves) probe_zeroing else probe_ok;
        return .{ .value = best, .state = state };
    }
    return .{ .value = value, .state = probe_ok };
}

// SF probe_dtz: DTZ from the side-to-move's view. Uses search<true> to fold in zeroing pawn moves,
// then probe_table<DTZ>; the CHANGE_STM branch does a 1-ply search that minimizes DTZ (the DTZ
// table stored the other side, so we step one move and read the resulting DTZ).
fn probeDtz(pos: *Position, storage: *state_list.PendingStateStorage, out_state: *i32) i32 {
    out_state.* = probe_ok;
    const w = searchWdl(pos, storage, true);
    if (w.state == probe_fail) {
        out_state.* = probe_fail;
        return 0;
    }
    const wdl = w.value;
    if (wdl == wdl_draw) return 0; // DTZ tables don't store draws
    if (w.state == probe_zeroing) return dtzBeforeZeroing(wdl); // best move is a winning zeroing move

    var st: i32 = probe_ok;
    const dtz = probeTable(pos, true, wdl, &st);
    if (st == probe_fail) {
        out_state.* = probe_fail;
        return 0;
    }
    if (st != change_stm) {
        const cursed: i32 = @intFromBool(wdl == wdl_blessed_loss or wdl == wdl_cursed_win);
        return (dtz + 100 * cursed) * signOf(wdl);
    }

    // CHANGE_STM: the DTZ is stored for the other side; do a 1-ply search minimizing DTZ.
    var min_dtz: i32 = 0xFFFF;
    var buf: [256]u16 = undefined;
    const total = movegen.generateLegal(pos, buf[0..].ptr);
    const node = state_list.storagePush(storage) catch {
        out_state.* = probe_fail;
        return 0;
    };
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const m = buf[i];
        const zeroing = isCapture(pos, m) or movedPieceType(pos, m) == pawn_pt;
        position.doMoveState(pos, m, node);
        var cst: i32 = probe_ok;
        var d: i32 = undefined;
        if (zeroing) {
            const s = searchWdl(pos, storage, false);
            cst = s.state;
            d = -dtzBeforeZeroing(s.value);
        } else {
            d = -probeDtz(pos, storage, &cst);
        }
        // A mating move gets DTZ 1 (child is in check with no legal reply).
        var mbuf: [256]u16 = undefined;
        if (d == 1 and pos.st.checkers_bb != 0 and movegen.generateLegal(pos, mbuf[0..].ptr) == 0)
            min_dtz = 1;
        if (!zeroing) d += signOf(d); // correct for the 1-ply search
        if (d < min_dtz and signOf(d) == signOf(wdl)) min_dtz = d;
        position.undoMove(pos, m);
        if (cst == probe_fail) {
            out_state.* = probe_fail;
            return 0;
        }
    }
    return if (min_dtz == 0xFFFF) -1 else min_dtz; // no legal moves -> mate -> -1
}

// ---- probeFen: the platform probe surface -----------------------------------

/// Probe a FEN for its WDL and DTZ. Builds a scratch Position (engine down-edge), then runs SF's
/// probe_wdl (search<false>) and probe_dtz. `available == 0` means no WDL result (no table, load
/// failure, or castling rights present -- TB positions have none); a DTZ failure is reported via
/// `dtz_state` while WDL still reports.
pub fn probeFen(fen_ptr: [*]const u8, fen_len: usize, chess960: u8) ProbeResult {
    const empty = ProbeResult{ .available = 0, .wdl = 0, .wdl_state = 0, .dtz = 0, .dtz_state = 0 };
    if (arena_state == null) return empty;

    const pos = position.create() orelse return empty;
    defer position.destroy(pos);
    const storage = state_list.storageCreate() orelse return empty;
    defer state_list.storageDestroy(storage);
    const root_state = state_list.storageReset(storage) catch return empty;
    if (position.setPositionState(pos, fen_ptr, fen_len, chess960, root_state)) |err| {
        std.heap.c_allocator.free(std.mem.span(err));
        return empty;
    }

    const w = searchWdl(pos, storage, false); // probe_wdl
    if (w.state == probe_fail) return empty;

    var dtz_state: i32 = probe_ok;
    const dtz = probeDtz(pos, storage, &dtz_state);

    return .{
        .available = 1,
        .wdl = w.value,
        .wdl_state = w.state,
        .dtz = dtz,
        .dtz_state = dtz_state,
    };
}

// In-search WDL probe (M-SZ-4): the search's Step 6 calls this on the LIVE search Position rather
// than round-tripping a FEN. searchWdl does do/undo on `pos` for its capture recursion and restores
// it exactly (undoMove), and doMoveState touches only the board + StateInfo (never the NNUE
// accumulator stack), so the search's position/eval state is intact on return. A persistent probe
// storage (reset per call) supplies the recursion's StateInfo nodes. Same WDL as the FEN path.
var probe_pos_storage: ?*state_list.PendingStateStorage = null;

pub fn probeWdlPos(pos: *Position) ProbeResult {
    const empty = ProbeResult{ .available = 0, .wdl = 0, .wdl_state = 0, .dtz = 0, .dtz_state = 0 };
    if (arena_state == null) return empty;
    if (probe_pos_storage == null) probe_pos_storage = state_list.storageCreate();
    const storage = probe_pos_storage orelse return empty;
    _ = state_list.storageReset(storage) catch return empty;

    const w = searchWdl(pos, storage, false);
    if (w.state == probe_fail) return empty;
    return .{ .available = 1, .wdl = w.value, .wdl_state = w.state, .dtz = 0, .dtz_state = 0 };
}

test {
    std.testing.refAllDecls(@This());
}
