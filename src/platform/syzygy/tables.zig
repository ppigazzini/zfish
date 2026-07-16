//! Discover Syzygy tablebases: scan SyzygyPath, count the `.rtbw`/`.rtbz` files
//! that exist, and report `maxCardinality`. Mirror Stockfish `Tablebases::init` +
//! `TBTables::add`: enumerate every King-vs-King material configuration up to 7 men, build the
//! canonical file name, and count a table by FILE EXISTENCE (`is_open()` -- the magic header is
//! validated later, at probe time, not here). Do no probing yet: this is load + init only, so with
//! no path set the engine behaves exactly as before (bench 2466447 unchanged).
//!
//! Keep this in the platform layer: file I/O is a platform service, and this slice touches no engine types.

const std = @import("std");
const builtin = @import("builtin");
const registry = @import("registry.zig");

// Match Stockfish PieceType indices: 1=Pawn 2=Knight 3=Bishop 4=Rook 5=Queen 6=King.
const piece_char = " PNBRQK"; // index by piece type; `code += PieceToChar[pt]`
const king: u8 = 6;
const pawn: u8 = 1;
const sep_char: u8 = if (builtin.os.tag == .windows) ';' else ':';

var found_wdl: usize = 0;
var found_dtz: usize = 0;
var max_card: usize = 0;
var path_buf: [4096]u8 = undefined;
var path_str: []const u8 = "";

/// Report the largest piece count DISCOVERED on disk (for the "up to N-man" message).
pub fn discoveredMax() usize {
    return max_card;
}

/// Return the search-facing max cardinality: the largest position the WDL prober can serve.
/// Equal to `max_card` (the largest table discovered on disk). With no SyzygyPath set this is 0,
/// so a default build -- and `bench`, which never sets a path -- takes no tablebase path and the
/// signature is unchanged. DTZ/root ranking are bounded by the same value.
pub fn maxCardinality() usize {
    return max_card;
}
pub fn foundWdl() usize {
    return found_wdl;
}
pub fn foundDtz() usize {
    return found_dtz;
}

// Build the Syzygy file stem: concat PieceToChar[pt], then insert 'v' before the second 'K'
// (SF `TBTables::add`). E.g. {K,Q,K} -> "KQK" -> "KQvK"; {K,R,P,K,R} -> "KRPKR" -> "KRPvKR".
fn buildName(pieces: []const u8, out: *[16]u8) []const u8 {
    var n: usize = 0;
    for (pieces) |pt| {
        out[n] = piece_char[pt];
        n += 1;
    }
    var k: usize = 1;
    while (k < n and out[k] != 'K') k += 1;
    var j: usize = n;
    while (j > k) : (j -= 1) out[j] = out[j - 1];
    out[k] = 'v';
    return out[0 .. n + 1];
}

fn fileExists(full: []const u8) bool {
    // Call libc `access(path, F_OK)` -- the port does file/OS calls through libc (std.c.*), and this
    // needs no `Io` (the tablebase.init seam carries none). F_OK == 0.
    var zbuf: [4097]u8 = undefined;
    if (full.len >= zbuf.len) return false;
    @memcpy(zbuf[0..full.len], full);
    zbuf[full.len] = 0;
    const z: [*:0]const u8 = @ptrCast(&zbuf);
    return std.c.access(z, 0) == 0;
}

// Report true if `<stem><ext>` exists in any of the (sep-separated) SyzygyPath directories.
fn tbFileExists(stem: []const u8, ext: []const u8) bool {
    var it = std.mem.splitScalar(u8, path_str, sep_char);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}{s}", .{ dir, stem, ext }) catch continue;
        if (fileExists(full)) return true;
    }
    return false;
}

// Port SF `TBTables::add`: count the DTZ file if present, then the WDL file (required -- a table is
// only "found" when its .rtbw exists), and raise maxCardinality to this config's piece count.
fn add(pieces: []const u8) void {
    var nb: [16]u8 = undefined;
    const stem = buildName(pieces, &nb);
    if (tbFileExists(stem, ".rtbz")) found_dtz += 1;
    if (!tbFileExists(stem, ".rtbw")) return;
    found_wdl += 1;
    if (pieces.len > max_card) max_card = pieces.len;
    registry.register(pieces); // register the WDL table in the probe registry
}

// Port SF `Tablebases::init`: enumerate every material configuration up to 7 men and `add` each.
pub fn init(path_ptr: [*]const u8, path_len: usize) void {
    found_wdl = 0;
    found_dtz = 0;
    max_card = 0;
    if (path_len == 0) {
        path_str = "";
        registry.reset("");
        return;
    }
    const src = path_ptr[0..path_len];
    const n = @min(src.len, path_buf.len);
    @memcpy(path_buf[0..n], src[0..n]);
    path_str = path_buf[0..n];
    registry.reset(path_str); // (re)build the probe registry for this path

    var p1: u8 = pawn;
    while (p1 < king) : (p1 += 1) {
        add(&[_]u8{ king, p1, king });
        var p2: u8 = pawn;
        while (p2 <= p1) : (p2 += 1) {
            add(&[_]u8{ king, p1, p2, king });
            add(&[_]u8{ king, p1, king, p2 });
            var p3: u8 = pawn;
            while (p3 < king) : (p3 += 1) add(&[_]u8{ king, p1, p2, king, p3 });
            p3 = pawn;
            while (p3 <= p2) : (p3 += 1) {
                add(&[_]u8{ king, p1, p2, p3, king });
                var p4: u8 = pawn;
                while (p4 <= p3) : (p4 += 1) {
                    add(&[_]u8{ king, p1, p2, p3, p4, king });
                    var p5a: u8 = pawn;
                    while (p5a <= p4) : (p5a += 1) add(&[_]u8{ king, p1, p2, p3, p4, p5a, king });
                    var p5b: u8 = pawn;
                    while (p5b < king) : (p5b += 1) add(&[_]u8{ king, p1, p2, p3, p4, king, p5b });
                }
                var p4b: u8 = pawn;
                while (p4b < king) : (p4b += 1) {
                    add(&[_]u8{ king, p1, p2, p3, king, p4b });
                    var p5c: u8 = pawn;
                    while (p5c <= p4b) : (p5c += 1) add(&[_]u8{ king, p1, p2, p3, king, p4b, p5c });
                }
            }
            p3 = pawn;
            while (p3 <= p1) : (p3 += 1) {
                var p4c: u8 = pawn;
                const p4max = if (p1 == p3) p2 else p3;
                while (p4c <= p4max) : (p4c += 1) add(&[_]u8{ king, p1, p2, king, p3, p4c });
            }
        }
    }
}

test "buildName matches SF file stems" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("KQvK", buildName(&[_]u8{ king, 5, king }, &b));
    try std.testing.expectEqualStrings("KPvK", buildName(&[_]u8{ king, 1, king }, &b));
    try std.testing.expectEqualStrings("KRPvKR", buildName(&[_]u8{ king, 4, 1, king, 4 }, &b));
    try std.testing.expectEqualStrings("KQvKR", buildName(&[_]u8{ king, 5, king, 4 }, &b));
}

test "init on an empty path finds nothing" {
    init("", 0);
    try std.testing.expectEqual(@as(usize, 0), maxCardinality());
    try std.testing.expectEqual(@as(usize, 0), foundWdl());
}
