const builtin = @import("builtin");
const build_options = @import("build_options");
const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

extern fn zfish_misc_has_large_pages_flag() u8;
extern fn zfish_misc_hardware_concurrency_value() c_int;

const max_debug_slots: usize = 32;
const version = "dev";
const fallback_build_date = computeFallbackBuildDate();

var dbg_hit: [max_debug_slots][2]i64 = .{.{ 0, 0 }} ** max_debug_slots;
var dbg_mean: [max_debug_slots][2]i64 = .{.{ 0, 0 }} ** max_debug_slots;
var dbg_stdev: [max_debug_slots][3]i64 = .{.{ 0, 0, 0 }} ** max_debug_slots;
var dbg_correl: [max_debug_slots][6]i64 = .{.{ 0, 0, 0, 0, 0, 0 }} ** max_debug_slots;
var dbg_extremes_count: [max_debug_slots]i64 = [_]i64{0} ** max_debug_slots;
var dbg_extremes_max: [max_debug_slots]i64 = [_]i64{std.math.minInt(i64)} ** max_debug_slots;
var dbg_extremes_min: [max_debug_slots]i64 = [_]i64{std.math.maxInt(i64)} ** max_debug_slots;

pub fn hashBytes(data: []const u8) u64 {
    const m: u64 = 0xc6a4a7935bd1e995;
    const r: u6 = 47;

    var hash: u64 = @as(u64, data.len) *% m;
    const aligned_end = data.len & ~@as(usize, 7);

    var index: usize = 0;
    while (index < aligned_end) : (index += 8) {
        var k = std.mem.readInt(u64, data[index..][0..8], .little);
        k *%= m;
        k ^= k >> r;
        k *%= m;

        hash ^= k;
        hash *%= m;
    }

    if ((data.len & 7) != 0) {
        var k: u64 = 0;
        var tail_index = data.len & 7;
        while (tail_index != 0) {
            tail_index -= 1;
            k = (k << 8) | data[aligned_end + tail_index];
        }
        hash ^= k;
        hash *%= m;
    }

    hash ^= hash >> r;
    hash *%= m;
    hash ^= hash >> r;

    return hash;
}

pub fn strToSizeT(input: []const u8) usize {
    var index: usize = 0;
    while (index < input.len and isSpaceByte(input[index])) : (index += 1) {}

    if (index < input.len and input[index] == '+') {
        index += 1;
    }

    const digits_start = index;
    var value: u64 = 0;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte < '0' or byte > '9') {
            break;
        }

        const digit = @as(u64, byte - '0');
        const multiplied = @mulWithOverflow(value, @as(u64, 10));
        if (multiplied[1] != 0) {
            c.exit(c.EXIT_FAILURE);
        }

        const next_value = @addWithOverflow(multiplied[0], digit);
        if (next_value[1] != 0) {
            c.exit(c.EXIT_FAILURE);
        }

        value = next_value[0];
    }

    if (digits_start == index) {
        c.exit(c.EXIT_FAILURE);
    }

    if (value > std.math.maxInt(usize)) {
        c.exit(c.EXIT_FAILURE);
    }
    return @intCast(value);
}

pub fn readFileToString(path: []const u8) ?[*:0]u8 {
    return readFileToStringAlloc(path) catch null;
}

pub fn removeWhitespace(input: []const u8) ?[*:0]u8 {
    return removeWhitespaceAlloc(input) catch null;
}

pub fn isWhitespace(input: []const u8) bool {
    for (input) |byte| {
        if (!isSpaceByte(byte)) {
            return false;
        }
    }
    return true;
}

pub fn getBinaryDirectory(argv0: []const u8) ?[*:0]u8 {
    return getBinaryDirectoryAlloc(argv0) catch null;
}

pub fn getWorkingDirectory() ?[*:0]u8 {
    return getWorkingDirectoryAlloc() catch null;
}

pub fn engineVersionInfoText() ?[*:0]u8 {
    if (!std.mem.eql(u8, version, "dev")) {
        return allocFormattedCString("Stockfish {s}", .{version}) catch null;
    }

    return allocFormattedCString(
        "Stockfish {s}-{s}-{s}",
        .{ version, gitDateText(), gitShaText() },
    ) catch null;
}

pub fn engineInfoText(to_uci: u8) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const version_text = engineVersionOwned(allocator) catch return null;
    defer allocator.free(version_text);

    return allocFormattedCString(
        "{s}{s}the Stockfish developers (see AUTHORS file)",
        .{ version_text, if (to_uci != 0) "\nid author " else " by " },
    ) catch null;
}

pub fn compilerInfoText() ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const compiler_name = compilerNameOwned(allocator) catch return null;
    defer allocator.free(compiler_name);
    const settings = compilationSettingsOwned(allocator) catch return null;
    defer allocator.free(settings);

    return allocFormattedCString(
        "\nCompiled by                : {s}{s}\n" ++
            "Compilation architecture   : {s}\n" ++
            "Compilation settings       : {s}\n" ++
            "Compiler __VERSION__ macro : {s}\n",
        .{
            compiler_name,
            compilerOsText(),
            compilationArchText(),
            settings,
            compilerVersionMacroText(),
        },
    ) catch null;
}

pub fn hasLargePages() bool {
    return zfish_misc_has_large_pages_flag() != 0;
}

pub fn hardwareConcurrency() c_int {
    return zfish_misc_hardware_concurrency_value();
}

pub fn dbgHitOn(cond: bool, slot: c_int) void {
    const index = slotIndex(slot);
    _ = @atomicRmw(i64, &dbg_hit[index][0], .Add, 1, .seq_cst);
    if (cond) {
        _ = @atomicRmw(i64, &dbg_hit[index][1], .Add, 1, .seq_cst);
    }
}

pub fn dbgMeanOf(value: i64, slot: c_int) void {
    const index = slotIndex(slot);
    _ = @atomicRmw(i64, &dbg_mean[index][0], .Add, 1, .seq_cst);
    _ = @atomicRmw(i64, &dbg_mean[index][1], .Add, value, .seq_cst);
}

pub fn dbgStdevOf(value: i64, slot: c_int) void {
    const index = slotIndex(slot);
    _ = @atomicRmw(i64, &dbg_stdev[index][0], .Add, 1, .seq_cst);
    _ = @atomicRmw(i64, &dbg_stdev[index][1], .Add, value, .seq_cst);
    _ = @atomicRmw(i64, &dbg_stdev[index][2], .Add, value * value, .seq_cst);
}

pub fn dbgExtremesOf(value: i64, slot: c_int) void {
    const index = slotIndex(slot);
    _ = @atomicRmw(i64, &dbg_extremes_count[index], .Add, 1, .seq_cst);

    var current_max = @atomicLoad(i64, &dbg_extremes_max[index], .seq_cst);
    while (current_max < value) {
        const previous = @cmpxchgWeak(i64, &dbg_extremes_max[index], current_max, value, .seq_cst, .seq_cst);
        if (previous == null) {
            break;
        }
        current_max = previous.?;
    }

    var current_min = @atomicLoad(i64, &dbg_extremes_min[index], .seq_cst);
    while (current_min > value) {
        const previous = @cmpxchgWeak(i64, &dbg_extremes_min[index], current_min, value, .seq_cst, .seq_cst);
        if (previous == null) {
            break;
        }
        current_min = previous.?;
    }
}

pub fn dbgCorrelOf(value1: i64, value2: i64, slot: c_int) void {
    const index = slotIndex(slot);
    _ = @atomicRmw(i64, &dbg_correl[index][0], .Add, 1, .seq_cst);
    _ = @atomicRmw(i64, &dbg_correl[index][1], .Add, value1, .seq_cst);
    _ = @atomicRmw(i64, &dbg_correl[index][2], .Add, value1 * value1, .seq_cst);
    _ = @atomicRmw(i64, &dbg_correl[index][3], .Add, value2, .seq_cst);
    _ = @atomicRmw(i64, &dbg_correl[index][4], .Add, value2 * value2, .seq_cst);
    _ = @atomicRmw(i64, &dbg_correl[index][5], .Add, value1 * value2, .seq_cst);
}

pub fn dbgPrint() void {
    var index: usize = 0;
    while (index < max_debug_slots) : (index += 1) {
        const total = @atomicLoad(i64, &dbg_hit[index][0], .seq_cst);
        if (total != 0) {
            const hits = @atomicLoad(i64, &dbg_hit[index][1], .seq_cst);
            std.debug.print(
                "Hit #{d}: Total {d} Hits {d} Hit Rate (%) {}\n",
                .{ index, total, hits, 100.0 * asFloat(hits) / asFloat(total) },
            );
        }
    }

    index = 0;
    while (index < max_debug_slots) : (index += 1) {
        const total = @atomicLoad(i64, &dbg_mean[index][0], .seq_cst);
        if (total != 0) {
            const sum = @atomicLoad(i64, &dbg_mean[index][1], .seq_cst);
            std.debug.print("Mean #{d}: Total {d} Mean {}\n", .{ index, total, asFloat(sum) / asFloat(total) });
        }
    }

    index = 0;
    while (index < max_debug_slots) : (index += 1) {
        const total = @atomicLoad(i64, &dbg_stdev[index][0], .seq_cst);
        if (total != 0) {
            const sum = @atomicLoad(i64, &dbg_stdev[index][1], .seq_cst);
            const sum_sq = @atomicLoad(i64, &dbg_stdev[index][2], .seq_cst);
            const mean = asFloat(sum) / asFloat(total);
            const variance = asFloat(sum_sq) / asFloat(total) - mean * mean;
            std.debug.print("Stdev #{d}: Total {d} Stdev {}\n", .{ index, total, @sqrt(@max(variance, 0.0)) });
        }
    }

    index = 0;
    while (index < max_debug_slots) : (index += 1) {
        const total = @atomicLoad(i64, &dbg_extremes_count[index], .seq_cst);
        if (total != 0) {
            std.debug.print(
                "Extremity #{d}: Total {d} Min {d} Max {d}\n",
                .{
                    index,
                    total,
                    @atomicLoad(i64, &dbg_extremes_min[index], .seq_cst),
                    @atomicLoad(i64, &dbg_extremes_max[index], .seq_cst),
                },
            );
        }
    }

    index = 0;
    while (index < max_debug_slots) : (index += 1) {
        const total = @atomicLoad(i64, &dbg_correl[index][0], .seq_cst);
        if (total != 0) {
            const sum1 = asFloat(@atomicLoad(i64, &dbg_correl[index][1], .seq_cst));
            const sum1_sq = asFloat(@atomicLoad(i64, &dbg_correl[index][2], .seq_cst));
            const sum2 = asFloat(@atomicLoad(i64, &dbg_correl[index][3], .seq_cst));
            const sum2_sq = asFloat(@atomicLoad(i64, &dbg_correl[index][4], .seq_cst));
            const sum12 = asFloat(@atomicLoad(i64, &dbg_correl[index][5], .seq_cst));
            const n = asFloat(total);
            const numerator = sum12 / n - (sum1 / n) * (sum2 / n);
            const denom_left = @sqrt(@max(sum1_sq / n - (sum1 / n) * (sum1 / n), 0.0));
            const denom_right = @sqrt(@max(sum2_sq / n - (sum2 / n) * (sum2 / n), 0.0));
            const coefficient = if (denom_left == 0.0 or denom_right == 0.0) 0.0 else numerator / (denom_left * denom_right);
            std.debug.print("Correl. #{d}: Total {d} Coefficient {}\n", .{ index, total, coefficient });
        }
    }
}

pub fn dbgClear() void {
    var index: usize = 0;
    while (index < max_debug_slots) : (index += 1) {
        @atomicStore(i64, &dbg_hit[index][0], 0, .seq_cst);
        @atomicStore(i64, &dbg_hit[index][1], 0, .seq_cst);
        @atomicStore(i64, &dbg_mean[index][0], 0, .seq_cst);
        @atomicStore(i64, &dbg_mean[index][1], 0, .seq_cst);
        @atomicStore(i64, &dbg_stdev[index][0], 0, .seq_cst);
        @atomicStore(i64, &dbg_stdev[index][1], 0, .seq_cst);
        @atomicStore(i64, &dbg_stdev[index][2], 0, .seq_cst);
        @atomicStore(i64, &dbg_correl[index][0], 0, .seq_cst);
        @atomicStore(i64, &dbg_correl[index][1], 0, .seq_cst);
        @atomicStore(i64, &dbg_correl[index][2], 0, .seq_cst);
        @atomicStore(i64, &dbg_correl[index][3], 0, .seq_cst);
        @atomicStore(i64, &dbg_correl[index][4], 0, .seq_cst);
        @atomicStore(i64, &dbg_correl[index][5], 0, .seq_cst);
        @atomicStore(i64, &dbg_extremes_count[index], 0, .seq_cst);
        @atomicStore(i64, &dbg_extremes_max[index], std.math.minInt(i64), .seq_cst);
        @atomicStore(i64, &dbg_extremes_min[index], std.math.maxInt(i64), .seq_cst);
    }
}

fn readFileToStringAlloc(path: []const u8) ![*:0]u8 {
    const allocator = std.heap.c_allocator;
    const contents = try readFileAlloc(allocator, path);
    defer allocator.free(contents);
    return try allocCString(contents);
}

fn removeWhitespaceAlloc(input: []const u8) ![*:0]u8 {
    const allocator = std.heap.c_allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    for (input) |byte| {
        if (!isSpaceByte(byte)) {
            try buffer.append(allocator, byte);
        }
    }

    return try allocCString(buffer.items);
}

fn getBinaryDirectoryAlloc(argv0: []const u8) ![*:0]u8 {
    const allocator = std.heap.c_allocator;
    const path_separator = "/";
    const working_directory = try takeOwnedString(try getWorkingDirectoryAlloc());
    defer allocator.free(working_directory);

    var binary_directory = std.ArrayList(u8).empty;
    defer binary_directory.deinit(allocator);
    try binary_directory.appendSlice(allocator, argv0);

    const separator_index = std.mem.lastIndexOfAny(u8, binary_directory.items, "\\/");
    if (separator_index) |index| {
        binary_directory.shrinkRetainingCapacity(index + 1);
    } else {
        binary_directory.clearRetainingCapacity();
        try binary_directory.appendSlice(allocator, ".");
        try binary_directory.appendSlice(allocator, path_separator);
    }

    if (std.mem.startsWith(u8, binary_directory.items, "." ++ path_separator)) {
        var resolved = std.ArrayList(u8).empty;
        defer resolved.deinit(allocator);
        try resolved.appendSlice(allocator, working_directory);
        try resolved.appendSlice(allocator, binary_directory.items[1..]);
        return try allocCString(resolved.items);
    }

    return try allocCString(binary_directory.items);
}

fn getWorkingDirectoryAlloc() ![*:0]u8 {
    var buffer: [40000]u8 = undefined;
    const cwd = c.getcwd(@ptrCast(&buffer), buffer.len);
    if (cwd == null) {
        return try allocCString("");
    }

    const length = std.mem.indexOfScalar(u8, &buffer, 0) orelse buffer.len;
    return try allocCString(buffer[0..length]);
}

fn allocFormattedCString(comptime fmt: []const u8, args: anytype) ![*:0]u8 {
    const allocator = std.heap.c_allocator;
    const rendered = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(rendered);
    return try allocCString(rendered);
}

fn slotIndex(slot: c_int) usize {
    std.debug.assert(slot >= 0 and slot < max_debug_slots);
    return @intCast(slot);
}

fn asFloat(value: i64) f64 {
    return @as(f64, @floatFromInt(value));
}

fn engineVersionOwned(allocator: std.mem.Allocator) ![]u8 {
    if (!std.mem.eql(u8, version, "dev")) {
        return std.fmt.allocPrint(allocator, "Stockfish {s}", .{version});
    }

    return std.fmt.allocPrint(
        allocator,
        "Stockfish {s}-{s}-{s}",
        .{ version, gitDateText(), gitShaText() },
    );
}

fn gitDateText() []const u8 {
    if (build_options.git_date.len != 0) {
        return build_options.git_date;
    }

    return fallback_build_date[0..];
}

fn gitShaText() []const u8 {
    if (build_options.git_sha.len != 0) {
        return build_options.git_sha;
    }

    return "nogit";
}

fn compilerNameOwned(allocator: std.mem.Allocator) ![]u8 {
    if (@hasDecl(c, "__INTEL_LLVM_COMPILER")) {
        return std.fmt.allocPrint(allocator, "ICX {d}", .{c.__INTEL_LLVM_COMPILER});
    }

    if (@hasDecl(c, "__clang__")) {
        return std.fmt.allocPrint(
            allocator,
            "clang++ {d}.{d}.{d}",
            .{ c.__clang_major__, c.__clang_minor__, c.__clang_patchlevel__ },
        );
    }

    if (@hasDecl(c, "_MSC_VER")) {
        return std.fmt.allocPrint(
            allocator,
            "MSVC (version {d}.{d})",
            .{ c._MSC_FULL_VER, c._MSC_BUILD },
        );
    }

    if (@hasDecl(c, "__e2k__") and @hasDecl(c, "__LCC__")) {
        return std.fmt.allocPrint(
            allocator,
            "MCST LCC (version {d}.{d}{d}.{d}{d})",
            .{
                @divTrunc(c.__LCC__, 100),
                @divTrunc(@mod(c.__LCC__, 100), 10),
                @mod(c.__LCC__, 10),
                @divTrunc(c.__LCC_MINOR__, 10),
                @mod(c.__LCC_MINOR__, 10),
            },
        );
    }

    if (@hasDecl(c, "__GNUC__")) {
        return std.fmt.allocPrint(
            allocator,
            "g++ (GNUC) {d}.{d}.{d}",
            .{ c.__GNUC__, c.__GNUC_MINOR__, c.__GNUC_PATCHLEVEL__ },
        );
    }

    return allocator.dupe(u8, "Unknown compiler (unknown version)");
}

fn compilerOsText() []const u8 {
    return switch (builtin.target.os.tag) {
        .macos => " on Apple",
        .windows => if (builtin.target.ptrBitWidth() == 64) " on Microsoft Windows 64-bit" else " on Microsoft Windows 32-bit",
        .linux => " on Linux",
        else => " on unknown system",
    };
}

fn compilationArchText() []const u8 {
    if (build_options.arch_name.len != 0) {
        return build_options.arch_name;
    }

    return "(undefined architecture)";
}

fn compilationSettingsOwned(allocator: std.mem.Allocator) ![]u8 {
    var settings = std.ArrayList(u8).empty;
    errdefer settings.deinit(allocator);

    try settings.appendSlice(allocator, if (builtin.target.ptrBitWidth() == 64) "64bit" else "32bit");
    if (build_options.use_avx512icl) try settings.appendSlice(allocator, " AVX512ICL");
    if (build_options.use_vnni) try settings.appendSlice(allocator, " VNNI");
    if (build_options.use_avx512) try settings.appendSlice(allocator, " AVX512");
    if (build_options.use_pext) try settings.appendSlice(allocator, " BMI2");
    if (build_options.use_avx2) try settings.appendSlice(allocator, " AVX2");
    if (build_options.use_sse41) try settings.appendSlice(allocator, " SSE41");
    if (build_options.use_ssse3) try settings.appendSlice(allocator, " SSSE3");
    if (build_options.use_sse2) try settings.appendSlice(allocator, " SSE2");
    if (build_options.use_neon_dotprod) {
        try settings.appendSlice(allocator, " NEON_DOTPROD");
    } else if (build_options.use_neon) {
        try settings.appendSlice(allocator, " NEON");
    }
    if (build_options.use_popcnt) try settings.appendSlice(allocator, " POPCNT");
    if (!build_options.has_ndebug) try settings.appendSlice(allocator, " DEBUG");

    return settings.toOwnedSlice(allocator);
}

fn compilerVersionMacroText() []const u8 {
    if (@hasDecl(c, "__VERSION__")) {
        return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(c.__VERSION__)), 0);
    }

    return "(undefined macro)";
}

fn computeFallbackBuildDate() [8]u8 {
    if (!@hasDecl(c, "__DATE__")) {
        return .{ '0', '0', '0', '0', '0', '0', '0', '0' };
    }

    const date = std.mem.span(c.__DATE__);
    const month = switch (date[0]) {
        'A' => if (date[1] == 'p') "04" else "08",
        'D' => "12",
        'F' => "02",
        'J' => switch (date[1]) {
            'a' => "01",
            'u' => if (date[2] == 'n') "06" else "07",
            else => "00",
        },
        'M' => if (date[2] == 'r') "03" else "05",
        'N' => "11",
        'O' => "10",
        'S' => "09",
        else => "00",
    };
    const day_tens = if (date[4] == ' ') '0' else date[4];

    return .{ date[7], date[8], date[9], date[10], month[0], month[1], day_tens, date[5] };
}

fn allocCString(value: []const u8) ![*:0]u8 {
    const allocator = std.heap.c_allocator;
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result[0..value.len], value);
    return result.ptr;
}

fn takeOwnedString(pointer: [*:0]u8) ![]u8 {
    const slice = std.mem.span(pointer);
    const allocator = std.heap.c_allocator;
    const owned = try allocator.alloc(u8, slice.len);
    @memcpy(owned, slice);
    c.free(@ptrCast(pointer));
    return owned;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const c_path = try allocCString(path);
    defer c.free(@ptrCast(c_path));

    const file = c.fopen(c_path, "rb") orelse return error.FileOpenFailed;
    defer _ = c.fclose(file);

    if (c.fseek(file, 0, c.SEEK_END) != 0) {
        return error.FileOpenFailed;
    }

    const file_size = c.ftell(file);
    if (file_size < 0) {
        return error.FileOpenFailed;
    }

    if (c.fseek(file, 0, c.SEEK_SET) != 0) {
        return error.FileOpenFailed;
    }

    const buffer = try allocator.alloc(u8, @intCast(file_size));
    errdefer allocator.free(buffer);

    const bytes_read = c.fread(buffer.ptr, 1, buffer.len, file);
    if (bytes_read != buffer.len and c.ferror(file) != 0) {
        return error.FileOpenFailed;
    }

    return buffer;
}

fn isSpaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}
