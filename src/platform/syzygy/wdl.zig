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

const Position = position.Position;
const StateInfo = position.StateInfo;
const PairsData = probe.PairsData;
const EntryInfo = probe.EntryInfo;

const ProbeResult = @import("tb_source").ProbeResult;

// SF PieceType / Color encodings (via board_core): W pawn=1..king=6, B pawn=9..king=14.
const pawn_pt = board_core.pawn_pt;
const king_pt = board_core.king_pt;

const wdl_magic = [4]u8{ 0x71, 0xE8, 0x23, 0x5D };
const sep_char: u8 = if (builtin.os.tag == .windows) ';' else ':';

// ---- TBTable + registry -----------------------------------------------------

const TBTable = struct {
    key: u64,
    key2: u64,
    piece_count: i32,
    has_pawns: bool,
    has_unique_pieces: bool,
    pawn_count: [2]u8,
    sides: usize, // 2 when key != key2, else 1
    stem: [8]u8 = [_]u8{0} ** 8, // canonical file stem, e.g. "KQvK"
    stem_len: usize = 0,
    ready: bool = false,
    base: ?[]const u8 = null, // whole file bytes (64-aligned base), null if load failed
    items: [2][4]PairsData = [_][4]PairsData{[_]PairsData{.{}} ** 4} ** 2,

    fn info(self: *const TBTable) EntryInfo {
        return .{
            .has_pawns = self.has_pawns,
            .has_unique_pieces = self.has_unique_pieces,
            .piece_count = self.piece_count,
            .pawn_count = self.pawn_count,
        };
    }

    fn get(self: *TBTable, stm: usize, f: usize) *PairsData {
        return &self.items[stm % self.sides][if (self.has_pawns) f else 0];
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

// Read <stem>.rtbw from the first SyzygyPath dir that has it into a 64-byte-aligned buffer.
// Returns the whole file (magic included) or null on any failure. The 64-alignment makes the
// data-section rounding in `set` match an mmap base. POSIX only (libc open/read); Windows file
// mapping (a distinct CreateFileMapping path) comes with M-SZ-4, so on Windows this yields null
// and the probe reports "unavailable" -- the same graceful path as a missing file.
fn loadFile(t: *TBTable) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;

    var it = std.mem.splitScalar(u8, reg_path, sep_char);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var zbuf: [4097]u8 = undefined;
        const full = std.fmt.bufPrint(&zbuf, "{s}/{s}.rtbw\x00", .{ dir, t.stem[0..t.stem_len] }) catch continue;
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
                if (!std.mem.eql(u8, buf[0..4], &wdl_magic)) break;
                return buf;
            }
            acc.appendSlice(arena(), chunk[0..@intCast(r)]) catch return null;
        }
    }
    return null;
}

// ---- set: parse the file's PairsData records (SF `set`) ---------------------

// SF `set` (WDL specialization: set_dtz_map is a no-op). `buf` is the whole file (64-aligned
// base); parsing starts at offset 4 (after the magic). Fills every (side,file) PairsData.
fn set(t: *TBTable, buf: []const u8) void {
    const e = t.info();
    var pos: usize = 4; // skip magic
    // First byte after magic: Split(1)/HasPawns(2) flags (asserted in SF; we trust the file).
    pos += 1;

    const sides = t.sides;
    const max_file: usize = if (t.has_pawns) 3 else 0; // FILE_D or FILE_A
    const pp = t.has_pawns and t.pawn_count[1] != 0;

    var f: usize = 0;
    while (f <= max_file) : (f += 1) {
        var i: usize = 0;
        while (i < sides) : (i += 1) t.items[i][f] = .{};

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
                t.items[i][f].pieces[k] = if (i != 0) buf[pos] >> 4 else buf[pos] & 0xF;
            }
            pos += 1;
        }
        i = 0;
        while (i < sides) : (i += 1) {
            probe.setGroups(&t.items[i][f], e, order[i], f);
        }
    }

    pos += pos & 1; // word alignment (base is 64-aligned, so pos parity == address parity)

    f = 0;
    while (f <= max_file) : (f += 1) {
        var i: usize = 0;
        while (i < sides) : (i += 1) {
            decode.setSizes(arena(), &t.items[i][f], buf, &pos) catch return;
        }
    }

    // set_dtz_map: WDL no-op.

    f = 0;
    while (f <= max_file) : (f += 1) {
        var i: usize = 0;
        while (i < sides) : (i += 1) {
            t.items[i][f].sparse_index = buf[pos..].ptr;
            pos += t.items[i][f].sparse_index_size * @sizeOf(probe.SparseEntry);
        }
    }
    f = 0;
    while (f <= max_file) : (f += 1) {
        var i: usize = 0;
        while (i < sides) : (i += 1) {
            t.items[i][f].block_length = buf[pos..].ptr;
            pos += @as(usize, t.items[i][f].block_length_size) * 2;
        }
    }
    f = 0;
    while (f <= max_file) : (f += 1) {
        var i: usize = 0;
        while (i < sides) : (i += 1) {
            pos = (pos + 0x3F) & ~@as(usize, 0x3F); // 64-byte alignment
            t.items[i][f].data = buf[pos..].ptr;
            pos += @as(usize, t.items[i][f].blocks_num) * t.items[i][f].sizeof_block;
        }
    }
}

// Lazy load + parse on first probe. Returns true if the table is usable.
fn mapped(t: *TBTable) bool {
    if (t.ready) return t.base != null;
    t.ready = true;
    const buf = loadFile(t) orelse {
        t.base = null;
        return false;
    };
    t.base = buf;
    set(t, buf);
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

// SF do_probe_table<WDL>. Returns the raw WDL score in -2..2 (map_score = value - 2).
fn doProbeTable(pos: *const Position, t: *TBTable) i32 {
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
        const pc = t.items[0][0].pieces[0] ^ flip_color;
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

    // check_dtz_stm for WDL is always true.

    // Gather the remaining pieces (all except the lead pawns).
    var b = pos.by_type_bb[0] ^ lead_pawns;
    while (b != 0) {
        const s: u8 = @intCast(@ctz(b));
        b &= b - 1;
        squares[size] = s ^ flip_squares;
        pieces_arr[size] = pos.board[s] ^ flip_color;
        size += 1;
    }

    const d = t.get(stm, tb_file);

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

    return decode.decompressPairs(d, idx) - 2; // map_score<WDL> = value - 2
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

// ---- probe_table<WDL> + probe_wdl -------------------------------------------

const probe_ok = 1; // SF ProbeState::OK
const probe_fail = 0; // SF ProbeState::FAIL

// SF probe_table<WDL>: KvK short-circuit, registry lookup, lazy map, do_probe_table.
fn probeTable(pos: *const Position, t: *TBTable, ok: *bool) i32 {
    if (@popCount(pos.by_type_bb[0]) == 2) return 0; // KvK draw
    if (!mapped(t)) {
        ok.* = false;
        return 0;
    }
    return doProbeTable(pos, t);
}

/// Probe the WDL of `pos`. Sets `ok` false on failure. pt2a implements the no-capture control
/// flow (SF search<false> with no capturing moves falls straight through to probe_table); the
/// full capture recursion lands in pt2b.
fn probeWdl(pos: *const Position, ok: *bool) i32 {
    const t = hashGet(pos.st.material_key) orelse {
        ok.* = false;
        return 0;
    };
    return probeTable(pos, t, ok);
}

// ---- probeFen: the platform probe surface -----------------------------------

/// Probe a FEN for its WDL. Builds a scratch Position (engine down-edge), looks up the material
/// key in the registry, and runs the probe. `available == 0` means no result (no table, load
/// failure, or castling rights present -- TB positions have none).
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

    var ok = true;
    const wdl = probeWdl(pos, &ok);
    if (!ok) return empty;
    return .{ .available = 1, .wdl = wdl, .wdl_state = probe_ok, .dtz = 0, .dtz_state = 0 };
}

test {
    std.testing.refAllDecls(@This());
}
