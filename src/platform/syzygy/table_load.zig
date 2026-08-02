//! Load one Syzygy table file and parse its per-(side, file) PairsData records -- Stockfish's
//! `TBTable::MappedFile` construction plus `set` / `set_dtz_map` (tbprobe.cpp).
//!
//! Split from registry.zig on the 500-line lint, along the boundary that file already draws: the
//! registry owns the material-key -> TBTable MAP, built once from the same enumeration as file
//! discovery and holding nothing a file said; this half owns everything read out of a `.rtbw` /
//! `.rtbz`, which is untrusted input from a mirror. That is also the boundary the safety rules
//! follow -- every function here runs once per table, off the probe path, so it can afford
//! `@setRuntimeSafety(true)` and refuse a table gracefully, exactly as decode_header.zig does
//! against decode.zig. The dependency runs registry -> table_load; never the reverse.

const std = @import("std");
const builtin = @import("builtin");

const probe = @import("probe.zig");
const decode = @import("decode.zig");
const decode_header = @import("decode_header.zig");
const registry = @import("registry.zig");
const thread_runtime = @import("thread_runtime");

const TBTable = registry.TBTable;
const arena = registry.arena;
const rdU16 = decode.rdU16;
const wdl_magic = registry.wdl_magic;
const dtz_magic = registry.dtz_magic;
const sep_char = registry.sep_char;

// Read <stem><ext> from the first SyzygyPath dir that has it into a 64-byte-aligned buffer,
// verifying `magic`. Return the whole file (magic included) or null on any failure. The
// 64-alignment makes the data-section rounding in `set` match an mmap base. POSIX only (libc
// open/read); Windows file mapping (a distinct CreateFileMapping path) is not yet implemented, so on
// Windows this yields null and the probe reports "unavailable" -- the graceful missing-file path.
fn loadFile(t: *TBTable, ext: []const u8, magic: [4]u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;

    var it = std.mem.splitScalar(u8, registry.searchPath(), sep_char);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var zbuf: [4097]u8 = undefined;
        const full = std.fmt.bufPrint(&zbuf, "{s}/{s}{s}\x00", .{ dir, t.stem[0..t.stem_len], ext }) catch continue;
        const z: [*:0]const u8 = @ptrCast(full.ptr);
        const fd = std.c.open(z, .{ .ACCMODE = .RDONLY });
        if (fd < 0) continue;
        defer _ = std.c.close(fd);

        // Read the whole file (glibc has no plain `fstat` symbol, so grow a buffer to EOF).
        var acc: std.ArrayList(u8) = .empty;
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
//
// Return false when the file cannot be parsed within its own length. A `.rtbw`/`.rtbz` is an
// untrusted external file and `pos` is advanced entirely by values read out of it, so a truncated
// or hostile table can drive every offset past the end -- which ReleaseFast does not check. The
// caller must then treat the table exactly as a missing one; a half-parsed table left reachable
// hands the probe empty regions and, before this bound existed, a null `[*]` deref.
fn set(t: *TBTable, comptime dtz: bool, buf: []const u8) bool {
    // Untrusted input, once per table, never on the probe path -- see decode.setSizes.
    @setRuntimeSafety(true);
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
        if (buf.len - pos < @as(usize, 1) + @intFromBool(pp)) return false;
        order[0][0] = @intCast(buf[pos] & 0xF);
        order[0][1] = if (pp) @intCast(buf[pos + 1] & 0xF) else 0xF;
        order[1][0] = @intCast(buf[pos] >> 4);
        order[1][1] = if (pp) @intCast(buf[pos + 1] >> 4) else 0xF;
        pos += @as(usize, 1) + @intFromBool(pp);

        var k: usize = 0;
        while (k < @as(usize, @intCast(t.piece_count))) : (k += 1) {
            if (pos >= buf.len) return false;
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
            decode_header.setSizes(arena(), t.get(dtz, i, f), buf, &pos) catch return false;
        }
    }

    if (dtz and !setDtzMap(t, buf, &pos, max_file)) return false;

    // Carve the three file-backed regions with a bound each. Their sizes come from the header
    // fields parsed above, so each is a promise the file makes about itself; `take` refuses the
    // ones the file cannot keep instead of handing the probe a slice past the end. The widths
    // multiply SATURATINGLY: blocks_num is a full u32 from the file, so an ordinary `*` can wrap
    // usize and turn an absurd promise into a small, satisfiable one. Saturating keeps it absurd,
    // and `take` then rejects it.
    f = 0;
    while (f <= max_file) : (f += 1) {
        var i: usize = 0;
        while (i < sides) : (i += 1) {
            const d = t.get(dtz, i, f);
            d.sparse_index = take(buf, &pos, d.sparse_index_size *| @sizeOf(probe.SparseEntry)) orelse
                return false;
        }
    }
    f = 0;
    while (f <= max_file) : (f += 1) {
        var i: usize = 0;
        while (i < sides) : (i += 1) {
            const d = t.get(dtz, i, f);
            d.block_length = take(buf, &pos, @as(usize, d.block_length_size) *| 2) orelse
                return false;
        }
    }
    f = 0;
    while (f <= max_file) : (f += 1) {
        var i: usize = 0;
        while (i < sides) : (i += 1) {
            pos = (pos + 0x3F) & ~@as(usize, 0x3F); // 64-byte alignment
            const d = t.get(dtz, i, f);
            d.data = takeAtMost(buf, &pos, @as(usize, d.blocks_num) *| d.sizeof_block) orelse
                return false;
        }
    }
    return true;
}

// Carve `n` bytes out of `buf` at `pos.*`, advancing it, or null if the file is too short. The
// 64-byte alignment rounding above can push `pos` past the end on a corrupt file, so test the
// cursor as well as the width.
fn take(buf: []const u8, pos: *usize, n: usize) ?[]const u8 {
    if (pos.* > buf.len or buf.len - pos.* < n) return null;
    const out = buf[pos.*..][0..n];
    pos.* += n;
    return out;
}

// Carve up to `n` bytes, stopping at the end of the file, or null if the cursor is already past
// it. The compressed data region is the one region a WELL-FORMED table declares longer than it
// stores: `blocks_num * sizeof_block` counts whole blocks, and the file holds only the used bytes
// of the final one -- upstream reads the tail out of the mmap's page padding, which zfish does not
// have (loadFile allocates exactly `size` bytes). Requiring the full declared width here rejected
// real 5-man tables and moved tb-cursed's node counts, so bound the region by the file instead;
// decompressPairs checks each block start against this length before reading it.
fn takeAtMost(buf: []const u8, pos: *usize, n: usize) ?[]const u8 {
    if (pos.* > buf.len) return null;
    const avail = @min(n, buf.len - pos.*);
    const out = buf[pos.*..][0..avail];
    pos.* += n;
    return out;
}

// Port SF `set_dtz_map`: read the per-file DTZ value-remap tables. `map_idx[i]` records the offset of
// each of the four WDL-class maps from `dtz_map` (u16 units when Wide, bytes otherwise, +1 as SF).
// Return false when a map runs past the file. Each map's width is read from the file immediately
// before it is skipped, so the cursor is entirely file-driven here too.
fn setDtzMap(t: *TBTable, buf: []const u8, pos: *usize, max_file: usize) bool {
    @setRuntimeSafety(true); // untrusted input, once per table -- see decode.setSizes
    // Test the cursor on ENTRY, before anything derives a width from it. setSizes word-aligns
    // past the btree (`p += symlen_size & 1`) without demanding that pad byte exist, so a
    // successful parse can leave the cursor exactly one past the end -- deliberately, since
    // requiring the byte would reject a table whose btree ends on the last one, which upstream
    // accepts. Every path out of this function happens to reject such a table anyway, but that
    // is a property of the control flow, not of the value, and the value is what bounds
    // wdl.mapScoreDtz (mcfish 4b240ec8).
    if (pos.* > buf.len) return false;
    const map_base = pos.*;
    var f: usize = 0;
    while (f <= max_file) : (f += 1) {
        const d = t.get(true, 0, f);
        if (d.flags & decode.flag_mapped != 0) {
            if (d.flags & decode.flag_wide != 0) {
                pos.* += pos.* & 1; // word align
                var i: usize = 0;
                while (i < 4) : (i += 1) {
                    if (pos.* + 2 > buf.len) return false;
                    d.map_idx[i] = @intCast((pos.* - map_base) / 2 + 1);
                    pos.* += 2 * @as(usize, rdU16(buf[pos.*..])) + 2;
                }
            } else {
                var i: usize = 0;
                while (i < 4) : (i += 1) {
                    if (pos.* >= buf.len) return false;
                    d.map_idx[i] = @intCast(pos.* - map_base + 1);
                    pos.* += @as(usize, buf[pos.*]) + 1;
                }
            }
        }
    }
    pos.* += pos.* & 1; // word align
    if (pos.* > buf.len) return false;
    // Bound the map region by what the cursor actually consumed: wdl.zig indexes it by the
    // map_idx offsets recorded above, which are all inside [map_base, pos.*).
    t.dtz_map = buf[map_base..pos.*];
    return true;
}

// Serialise the one-time load of every table, as upstream does with a function-local
// `static std::mutex` shared by both probes (tbprobe.cpp:1271).
var table_load_mutex: thread_runtime.Mutex = .{};

// Load + parse lazily on first probe. Return true if the WDL table is usable.
//
// Publish `ready` with a RELEASE store only after `set()` has filled the PairsData, and read it
// with ACQUIRE, so a thread taking the fast path either sees no table or sees one fully parsed.
// Announcing readiness before the load lets a concurrent probe read a null base as "table absent"
// or walk half-written PairsData. Upstream's mutex plus release-after-set forbids both.
pub fn mapped(t: *TBTable) bool {
    if (@atomicLoad(bool, &t.ready, .acquire)) return t.base != null;

    table_load_mutex.lock();
    defer table_load_mutex.unlock();
    // Re-check under the lock: another thread may have loaded it while this one waited.
    if (@atomicLoad(bool, &t.ready, .monotonic)) return t.base != null;

    const buf = loadFile(t, ".rtbw", wdl_magic) orelse {
        t.base = null;
        @atomicStore(bool, &t.ready, true, .release);
        return false;
    };
    // Publish the table only if it parsed within its own length. A file that does not is
    // reported exactly as a missing one -- `base = null`, probe says "unavailable" -- rather
    // than left half-parsed and reachable.
    if (!set(t, false, buf)) {
        t.base = null;
        @atomicStore(bool, &t.ready, true, .release);
        return false;
    }
    t.base = buf;
    @atomicStore(bool, &t.ready, true, .release);
    return true;
}

// Load + parse the DTZ (.rtbz) file lazily on first DTZ probe. Same publication order as mapped().
pub fn mappedDtz(t: *TBTable) bool {
    if (@atomicLoad(bool, &t.dtz_ready, .acquire)) return t.dtz_base != null;

    table_load_mutex.lock();
    defer table_load_mutex.unlock();
    if (@atomicLoad(bool, &t.dtz_ready, .monotonic)) return t.dtz_base != null;

    const buf = loadFile(t, ".rtbz", dtz_magic) orelse {
        t.dtz_base = null;
        @atomicStore(bool, &t.dtz_ready, true, .release);
        return false;
    };
    if (!set(t, true, buf)) {
        t.dtz_base = null;
        @atomicStore(bool, &t.dtz_ready, true, .release);
        return false;
    }
    t.dtz_base = buf;
    @atomicStore(bool, &t.dtz_ready, true, .release);
    return true;
}

test {
    std.testing.refAllDecls(@This());
}
