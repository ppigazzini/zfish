// UCI win-rate / centipawn / WDL model.
//
// A leaf module (std only): the internal-eval -> centipawn conversion and the
// win/draw/loss estimate share the same win-rate polynomial. Kept dependency-free so
// any layer can format a score without a cycle -- engine.zig (uci_to_cp) and the search
// driver's info-line emit both call it, and neither can import the uci module.

const std = @import("std");

const WinRateParams = struct { a: f64, b: f64 };

// UCI_WinRateModel params for the given non-pawn material (clamped 17..78).
fn winRateParams(material: c_int) WinRateParams {
    const clamped = std.math.clamp(material, 17, 78);
    const m = @as(f64, @floatFromInt(clamped)) / 58.0;
    const as = [_]f64{ -72.32565836, 185.93832038, -144.58862193, 416.44950446 };
    const bs = [_]f64{ 83.86794042, -136.06112997, 69.98820887, 47.62901433 };
    const a = (((as[0] * m + as[1]) * m + as[2]) * m) + as[3];
    const b = (((bs[0] * m + bs[1]) * m + bs[2]) * m) + bs[3];
    return .{ .a = a, .b = b };
}

fn winRateModel(value: c_int, material: c_int) c_int {
    const params = winRateParams(material);
    return @intFromFloat(0.5 + 1000.0 / (1.0 + std.math.exp((params.a - @as(f64, @floatFromInt(value))) / params.b)));
}

// Internal eval -> centipawns (UCI::to_cp): value normalised by the win-rate `a` param.
pub fn toCp(value: c_int, material: c_int) c_int {
    const params = winRateParams(material);
    return @intFromFloat(@round(100.0 * @as(f64, @floatFromInt(value)) / params.a));
}

// Allocated "win draw loss" permille triple (c_allocator; caller frees). null on OOM.
pub fn wdl(value: c_int, material: c_int) ?[*:0]u8 {
    return allocWdl(value, material) catch null;
}

// Allocated UCI score text: kind 0 -> "mate N", kind 1 -> TB "cp N", else "cp N".
pub fn formatScore(kind: u8, value: c_int, extra: c_int) ?[*:0]u8 {
    return allocScore(kind, value, extra) catch null;
}
fn allocScore(kind: u8, value: c_int, extra: c_int) !?[*:0]u8 {
    return switch (kind) {
        0 => blk: {
            const mate = @divTrunc(if (value > 0) value + 1 else value, 2);
            break :blk try allocFormatted("mate {d}", .{mate});
        },
        1 => blk: {
            const tb_cp: c_int = 20000;
            const score = (if (extra != 0) tb_cp else -tb_cp) - value;
            break :blk try allocFormatted("cp {d}", .{score});
        },
        else => try allocFormatted("cp {d}", .{value}),
    };
}

fn allocWdl(value: c_int, material: c_int) !?[*:0]u8 {
    const win = winRateModel(value, material);
    const loss = winRateModel(-value, material);
    const draw = 1000 - win - loss;
    return try allocFormatted("{d} {d} {d}", .{ win, draw, loss });
}

pub fn allocFormatted(comptime fmt: []const u8, args: anytype) !?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    return try allocCString(formatted);
}

pub fn allocCString(value: []const u8) !?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result[0..value.len], value);
    return result.ptr;
}

fn appendFormatted(buffer: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const allocator = std.heap.c_allocator;
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try buffer.appendSlice(allocator, formatted);
}

// "info depth D score S" for the no-legal-moves (mate/stalemate) case.
pub fn formatInfoNoMoves(depth: c_int, score_text: []const u8) ?[*:0]u8 {
    return allocFormatted("info depth {d} score {s}", .{ depth, score_text }) catch null;
}

// The full per-PV info line (depth/seldepth/multipv/score/[bound]/[wdl]/nodes/nps/
// hashfull/tbhits/time/pv). Relocated from uci.zig (M16.7).
pub fn formatInfoFull(
    depth: c_int,
    sel_depth: c_int,
    multi_pv: usize,
    score_text: []const u8,
    bound_text: []const u8,
    wdl_text: []const u8,
    show_wdl: u8,
    nodes: usize,
    nps: usize,
    hashfull: c_int,
    tb_hits: usize,
    time_ms: usize,
    pv: []const u8,
) ?[*:0]u8 {
    const ca = std.heap.c_allocator;
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(ca);

    builder.appendSlice(ca, "info depth ") catch return null;
    appendFormatted(&builder, "{d}", .{depth}) catch return null;
    builder.appendSlice(ca, " seldepth ") catch return null;
    appendFormatted(&builder, "{d}", .{sel_depth}) catch return null;
    builder.appendSlice(ca, " multipv ") catch return null;
    appendFormatted(&builder, "{d}", .{multi_pv}) catch return null;
    builder.appendSlice(ca, " score ") catch return null;
    builder.appendSlice(ca, score_text) catch return null;
    if (bound_text.len != 0) {
        builder.append(ca, ' ') catch return null;
        builder.appendSlice(ca, bound_text) catch return null;
    }
    if (show_wdl != 0) {
        builder.appendSlice(ca, " wdl ") catch return null;
        builder.appendSlice(ca, wdl_text) catch return null;
    }
    builder.appendSlice(ca, " nodes ") catch return null;
    appendFormatted(&builder, "{d}", .{nodes}) catch return null;
    builder.appendSlice(ca, " nps ") catch return null;
    appendFormatted(&builder, "{d}", .{nps}) catch return null;
    builder.appendSlice(ca, " hashfull ") catch return null;
    appendFormatted(&builder, "{d}", .{hashfull}) catch return null;
    builder.appendSlice(ca, " tbhits ") catch return null;
    appendFormatted(&builder, "{d}", .{tb_hits}) catch return null;
    builder.appendSlice(ca, " time ") catch return null;
    appendFormatted(&builder, "{d}", .{time_ms}) catch return null;
    builder.appendSlice(ca, " pv ") catch return null;
    builder.appendSlice(ca, pv) catch return null;

    return allocCString(builder.items) catch null;
}

// "info depth D currmove M currmovenumber N".
pub fn formatInfoIter(depth: c_int, currmove: []const u8, currmove_number: c_int) ?[*:0]u8 {
    return allocFormatted("info depth {d} currmove {s} currmovenumber {d}", .{ depth, currmove, currmove_number }) catch null;
}

// "bestmove M [ponder P]".
pub fn formatBestmove(bestmove: []const u8, ponder: []const u8) ?[*:0]u8 {
    if (ponder.len == 0) return allocFormatted("bestmove {s}", .{bestmove}) catch null;
    return allocFormatted("bestmove {s} ponder {s}", .{ bestmove, ponder }) catch null;
}
