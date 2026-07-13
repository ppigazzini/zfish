// zfish Syzygy 3-man tablebase fetcher, in pure Zig (mirrors fetch_net.zig) -- no sh/curl. It
// downloads the 5 three-man endgames (KPvK KNvK KBvK KRvK KQvK), WDL (.rtbw) + DTZ (.rtbz), into
// `syzygy/` under the cwd (build.zig runs it with cwd = net/, so -> net/syzygy/). ~26 KB total;
// the tables are NEVER committed (see .gitignore) -- fetched + cached like the NNUE net. Only the
// 3-man set is needed for the M-SZ CI gate (a KPvK/KQvK probe); it verifies each file's Syzygy
// magic header so a mirror error page can't masquerade as a table. Skips files already present.

const std = @import("std");
const Io = std.Io;

const names = [_][]const u8{ "KPvK", "KNvK", "KBvK", "KRvK", "KQvK" };
// First 4 bytes of a valid file (SF `Magics`): index [type == WDL] -> [0]=DTZ, [1]=WDL.
const wdl_magic = [4]u8{ 0x71, 0xE8, 0x23, 0x5D };
const dtz_magic = [4]u8{ 0xD7, 0x66, 0x0C, 0xA5 };
const base = "https://tablebase.lichess.ovh/tables/standard";

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fetch_tb: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Ensure syzygy/ exists (Io.Dir has no makeDir; libc mkdir, ignore EEXIST).
    _ = std.c.mkdir("syzygy", 0o755);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const Spec = struct { ext: []const u8, dir: []const u8, magic: [4]u8 };
    const specs = [_]Spec{
        .{ .ext = ".rtbw", .dir = "3-4-5-wdl", .magic = wdl_magic },
        .{ .ext = ".rtbz", .dir = "3-4-5-dtz", .magic = dtz_magic },
    };

    var fetched: usize = 0;
    for (names) |name| {
        for (specs) |spec| {
            const ext = spec.ext;
            const dir = spec.dir;
            const magic = spec.magic;
            const dst = try std.fmt.allocPrint(gpa, "syzygy/{s}{s}", .{ name, ext });
            defer gpa.free(dst);

            if (Io.Dir.cwd().access(io, dst, .{})) |_| {
                continue; // already present
            } else |_| {}

            const url = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}{s}", .{ base, dir, name, ext });
            defer gpa.free(url);
            var body: Io.Writer.Allocating = .init(gpa);
            defer body.deinit();
            const res = client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer }) catch |e|
                fatal("download failed {s} ({s})", .{ url, @errorName(e) });
            if (res.status != .ok) fatal("download failed {s} (HTTP {d})", .{ url, @intFromEnum(res.status) });
            const bytes = body.written();
            if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], &magic))
                fatal("bad magic for {s}{s} ({d} bytes) -- not a Syzygy file", .{ name, ext, bytes.len });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = bytes });
            fetched += 1;
        }
    }
    std.debug.print("fetch_tb: 3-man set ready in syzygy/ ({d} downloaded, {d} total)\n", .{ fetched, names.len * 2 });
}
