// zfish NNUE net fetcher, in pure Zig (M23.0), replacing tools/fetch_net.sh -- no `sh`, no external
// wget/curl/sha256sum, works on every OS. It downloads (and sha256-validates) the net the Zig binary
// ACTUALLY loads: the name is read at runtime from the authoritative Zig constant
// `default_eval_file_name` in src/engine/eval/network.zig (the single source of truth engine.zig imports),
// NOT the stale upstream src/evaluate.h that scripts/net.sh keys on. build.zig runs this with
// cwd = net/ and argv[1] = the path to network.zig.
//
// The name<->contents contract mirrors upstream: the file is named `nn-<first 12 hex of its
// sha256>.nnue`, so validation recomputes the sha256 and compares. Download sources + order match
// fetch_net.sh (tests.stockfishchess.org, then the official-stockfish/networks GitHub mirror).
//
// The pure helpers (parseNetName / nameFromBytes / validateBytes) are unit-tested against synthetic
// inputs; main() wires them to std.http.Client + std.Io file I/O. std.http.Client speaks TLS with the
// system CA bundle (auto-rescanned on the first HTTPS request), so there is no external cert tooling.

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

// A net filename is `nn-` ++ 12 lowercase-hex ++ `.nnue` == 20 bytes.
const name_len = 3 + 12 + 5;

fn isLowerHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

fn isValidNetName(name: []const u8) bool {
    if (name.len != name_len) return false;
    if (!std.mem.startsWith(u8, name, "nn-")) return false;
    if (!std.mem.endsWith(u8, name, ".nnue")) return false;
    for (name[3 .. 3 + 12]) |c| if (!isLowerHex(c)) return false;
    return true;
}

/// Extract the net filename from network.zig source, matching the single source of truth
/// `pub const default_eval_file_name = "nn-<12 hex>.nnue";`. Mirrors fetch_net.sh's sed capture.
fn parseNetName(src: []const u8) ?[]const u8 {
    const key = "default_eval_file_name = \"";
    const kpos = std.mem.indexOf(u8, src, key) orelse return null;
    const start = kpos + key.len;
    const end = std.mem.indexOfScalarPos(u8, src, start, '"') orelse return null;
    const name = src[start..end];
    return if (isValidNetName(name)) name else null;
}

/// The canonical filename for these bytes: `nn-` ++ first-12-hex-of-sha256 ++ `.nnue`.
fn nameFromBytes(bytes: []const u8, buf: *[name_len]u8) []const u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    const hex = "0123456789abcdef";
    @memcpy(buf[0..3], "nn-");
    for (digest[0..6], 0..) |b, i| {
        buf[3 + i * 2] = hex[b >> 4];
        buf[3 + i * 2 + 1] = hex[b & 0xf];
    }
    @memcpy(buf[15..20], ".nnue");
    return buf[0..name_len];
}

/// True iff `bytes` sha256-hash to the sha embedded in `name` (the upstream validity contract).
fn validateBytes(name: []const u8, bytes: []const u8) bool {
    var buf: [name_len]u8 = undefined;
    return std.mem.eql(u8, name, nameFromBytes(bytes, &buf));
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fetch_net: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next(); // argv0
    const net_src_path = arg_it.next() orelse fatal("usage: fetch_net <path-to-network.zig>", .{});

    // Read the net name from the authoritative Zig constant (so an upstream net bump is a one-line
    // network.zig edit -- this tracks the binary, never a stale header).
    const src = Io.Dir.cwd().readFileAlloc(io, net_src_path, gpa, .unlimited) catch |e|
        fatal("net-name source not found at '{s}' ({s})", .{ net_src_path, @errorName(e) });
    defer gpa.free(src);
    const name = parseNetName(src) orelse
        fatal("no default_eval_file_name in {s}", .{net_src_path});

    // cwd == net/ (set by build.zig). If the net is already present and valid, we are done.
    if (Io.Dir.cwd().readFileAlloc(io, name, gpa, .unlimited)) |existing| {
        defer gpa.free(existing);
        if (validateBytes(name, existing)) {
            std.debug.print("Existing {s} validated, skipping download\n", .{name});
            return;
        }
    } else |_| {}

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // Download sources + order match fetch_net.sh: the Fishtest API first, then the GitHub mirror.
    const urls = [_][]const u8{
        try std.fmt.allocPrint(gpa, "https://tests.stockfishchess.org/api/nn/{s}", .{name}),
        try std.fmt.allocPrint(gpa, "https://github.com/official-stockfish/networks/raw/master/{s}", .{name}),
    };
    defer for (urls) |u| gpa.free(u);
    for (urls) |url| {
        std.debug.print("Downloading {s} from {s} ...\n", .{ name, url });

        var body: Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        const res = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &body.writer,
        }) catch |e| {
            std.debug.print("Failed from {s} ({s})\n", .{ url, @errorName(e) });
            continue;
        };
        if (res.status != .ok) {
            std.debug.print("Failed from {s} (HTTP {d})\n", .{ url, @intFromEnum(res.status) });
            continue;
        }
        const bytes = body.written();
        if (!validateBytes(name, bytes)) {
            std.debug.print("Failed from {s} (sha256 mismatch, {d} bytes)\n", .{ url, bytes.len });
            continue;
        }
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = bytes });
        std.debug.print("Successfully validated {s}\n", .{name});
        return;
    }
    fatal("failed to download {s}", .{name});
}

test "parseNetName extracts the net filename from a network.zig snippet" {
    const src =
        \\pub const some_other = 1;
        \\pub const default_eval_file_name = "nn-af1339a6dea3.nnue";
        \\pub const tail = 2;
    ;
    try std.testing.expectEqualStrings("nn-af1339a6dea3.nnue", parseNetName(src).?);
}

test "parseNetName rejects a malformed name (wrong hex length)" {
    const src =
        \\pub const default_eval_file_name = "nn-af13.nnue";
    ;
    try std.testing.expect(parseNetName(src) == null);
}

test "parseNetName rejects uppercase hex (upstream names are lowercase)" {
    const src =
        \\pub const default_eval_file_name = "nn-AF1339A6DEA3.nnue";
    ;
    try std.testing.expect(parseNetName(src) == null);
}

test "parseNetName returns null when the constant is absent" {
    try std.testing.expect(parseNetName("pub const x = 1;") == null);
}

test "nameFromBytes derives nn-<first 12 hex of sha256>.nnue" {
    // sha256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    var buf: [name_len]u8 = undefined;
    try std.testing.expectEqualStrings("nn-e3b0c44298fc.nnue", nameFromBytes("", &buf));
}

test "validateBytes accepts matching contents and rejects tampered contents" {
    var buf: [name_len]u8 = undefined;
    const name = nameFromBytes("stockfish net payload", &buf);
    // nameFromBytes writes into buf; dupe so a later nameFromBytes call can't alias it.
    var name_copy: [name_len]u8 = undefined;
    @memcpy(&name_copy, name);
    try std.testing.expect(validateBytes(&name_copy, "stockfish net payload"));
    try std.testing.expect(!validateBytes(&name_copy, "tampered payload"));
}
