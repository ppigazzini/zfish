// Define the coverage-guided fuzz targets for the Syzygy file parse.
//
// A .rtbw/.rtbz is the only attacker-supplyable *binary* input the engine parses (the user
// points SyzygyPath at it), and every offset the parse advances is read out of that file. So
// the bounds in decode.zig are not a tidiness claim, they are the security boundary -- and a
// boundary with no fuzzer is a wish. Feed the header parse and the RE-PAIR decoder arbitrary
// bytes and require them to REJECT or SUCCEED, never to trap and never to leak.
//
// Import the decoder cluster by path: decode/probe/encode depend on std alone, so this root
// builds in isolation with no module graph, exactly like the standalone file tests.
//
// Build under ReleaseSafe (the `fuzz` step does) so a bound this file's targets get past trips
// a Zig safety check -- an out-of-range slice, an illegal @intCast, a bad shift width -- rather
// than reading whatever follows the buffer.

const std = @import("std");
const decode = @import("decode.zig");
const decode_header = @import("decode_header.zig");
const probe = @import("probe.zig");

// Give the PairsData the group state setSizes reads (`group_len` terminator -> `group_idx`
// entry -> tb_size). Keep the values small and self-consistent: the point is to fuzz the FILE
// bytes, not to fuzz zfish's own already-parsed state, and an absurd tb_size only starves the
// header parse of the branches worth exploring.
fn seedGroups(d: *probe.PairsData, seed: u8) void {
    d.group_len = @splat(0);
    d.group_idx = @splat(0);
    d.group_len[0] = 1;
    d.group_idx[0] = 1;
    d.group_idx[1] = @as(u64, seed) + 1;
}

// Require setSizes to survive arbitrary header bytes. It must return error.CorruptTable or fill
// a PairsData whose every region lies inside the buffer it was given -- checked explicitly here,
// because "did not crash" is a weaker claim than "stayed in bounds" and only the latter is what
// the probe path then relies on.
fn fuzzSetSizes(_: void, smith: *std.testing.Smith) anyerror!void {
    var raw: [256]u8 = undefined;
    smith.bytesWithHash(&raw, 2);
    const len = @as(usize, raw[0]) % raw.len;
    const buf = raw[0..len];

    var d = probe.PairsData{};
    seedGroups(&d, raw[1]);

    const a = std.testing.allocator;
    var pos: usize = 0;
    decode_header.setSizes(a, &d, buf, &pos) catch |err| {
        // Only CorruptTable and OutOfMemory are contractual; anything else is a new failure
        // mode the caller in registry.set does not know how to treat.
        if (err != error.CorruptTable and err != error.OutOfMemory) return err;
        return;
    };
    defer {
        a.free(d.base64);
        a.free(d.symlen);
    }

    // A successful parse must have consumed only bytes the file actually has, and must have
    // carved every file-backed region inside it.
    if (pos > buf.len) return error.CursorPastEndOfFile;
    if (!within(buf, d.lowest_sym)) return error.LowestSymOutsideFile;
    if (d.btree.len != 0 and !within(buf, std.mem.sliceAsBytes(d.btree)))
        return error.BtreeOutsideFile;

    // Every non-leaf child must index the tree -- the invariant probe.setSymLen's writes rely
    // on, and the one a corrupt table would otherwise break into an out-of-bounds store.
    for (d.btree) |entry| {
        if (entry.right() == 0xFFF) continue;
        if (entry.left() >= d.btree.len or entry.right() >= d.btree.len)
            return error.BtreeChildOutOfRange;
    }
}

// Report whether `part` lies wholly inside `whole`, by address.
fn within(whole: []const u8, part: []const u8) bool {
    if (part.len == 0) return true;
    const lo = @intFromPtr(whole.ptr);
    const hi = lo + whole.len;
    const plo = @intFromPtr(part.ptr);
    return plo >= lo and plo + part.len <= hi;
}

test "fuzz: setSizes rejects or bounds arbitrary header bytes" {
    try std.testing.fuzz({}, fuzzSetSizes, .{});
}

// Require decompressPairs to survive a fuzzer-built table. Parse a header out of the input,
// then hand the decoder whatever remains as its sparse index / block lengths / compressed data
// and probe it at fuzzer-chosen indices. This is the path that runs INSIDE the search, so it
// deliberately carries no blanket runtime safety -- which makes it exactly the path whose
// explicit bounds need a fuzzer behind them.
fn fuzzDecompressPairs(_: void, smith: *std.testing.Smith) anyerror!void {
    var raw: [512]u8 = undefined;
    smith.bytesWithHash(&raw, 4);

    var d = probe.PairsData{};
    seedGroups(&d, raw[1]);

    const a = std.testing.allocator;
    var pos: usize = 0;
    const header_len = @as(usize, raw[0]) % raw.len;
    decode_header.setSizes(a, &d, raw[0..header_len], &pos) catch return;
    defer {
        a.free(d.base64);
        a.free(d.symlen);
    }

    // Carve the remaining bytes into the three file-backed regions the registry would supply.
    // Their widths come from the parsed header, clamped to what is left -- the shape a
    // truncated real table has.
    const rest = raw[header_len..];
    var cut: usize = 0;
    d.sparse_index = slice(rest, &cut, d.sparse_index_size * @sizeOf(probe.SparseEntry));
    d.block_length = slice(rest, &cut, @as(usize, d.block_length_size) * 2);
    d.data = slice(rest, &cut, @as(usize, d.blocks_num) *| d.sizeof_block);

    // Probe at several indices drawn from the input. The result is unconstrained -- a garbage
    // table decodes to garbage -- so assert only that it terminates in bounds.
    for (0..4) |i| {
        const idx: u64 = raw[2 + i];
        _ = decode.decompressPairs(&d, idx);
    }
}

// Take up to `n` bytes at `cut`, advancing it; empty once the buffer is spent.
fn slice(buf: []const u8, cut: *usize, n: usize) []const u8 {
    if (cut.* >= buf.len) return &.{};
    const take = @min(n, buf.len - cut.*);
    const out = buf[cut.*..][0..take];
    cut.* += take;
    return out;
}

test "fuzz: decompressPairs stays in bounds on a fuzzer-built table" {
    try std.testing.fuzz({}, fuzzDecompressPairs, .{});
}
