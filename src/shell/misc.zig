const builtin = @import("builtin");
const build_options = @import("build_options");
const std = @import("std");
const c = @import("libc");
const memory = @import("memory");
// Keep the dbg_* debug statistics counters in their own std-only leaf now.
// Re-export them so the existing misc.dbg* API (misc.dbgPrint from uci.zig) is unchanged.
const debug_counters = @import("debug_counters.zig");
pub const dbgHitOn = debug_counters.dbgHitOn;
pub const dbgMeanOf = debug_counters.dbgMeanOf;
pub const dbgStdevOf = debug_counters.dbgStdevOf;
pub const dbgExtremesOf = debug_counters.dbgExtremesOf;
pub const dbgCorrelOf = debug_counters.dbgCorrelOf;
pub const dbgPrint = debug_counters.dbgPrint;
pub const dbgClear = debug_counters.dbgClear;

const version = "dev";
const fallback_build_date = computeFallbackBuildDate();

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
    return memory.hasLargePages();
}

pub fn hardwareConcurrency() c_int {
    // Return the number of hardware threads (Stockfish's get_hardware_concurrency).
    // Use std.Thread.getCpuCount(), the cross-platform equivalent -- sysconf(_SC_NPROCESSORS_ONLN)
    // on POSIX, GetSystemInfo on Windows -- so it matches the prior Linux glibc behavior while
    // also working on the owned Windows/macOS tiers. Clamp an error to 0.
    const n = std.Thread.getCpuCount() catch return 0;
    return std.math.cast(c_int, n) orelse 0;
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
    // Look up the cwd the idiomatic-Zig way, replacing libc getcwd. Use std.process.currentPath,
    // the cross-platform accessor (its Io vtable wraps POSIX getcwd / NT RtlGetCurrentDirectory);
    // rely on `init_single_threaded`, the same blocking, no-thread, no-signal-handler handle used
    // for the net-file read. On any failure keep the original "" fallback.
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var buffer: [40000]u8 = undefined;
    const length = std.process.currentPath(io, &buffer) catch {
        return try allocCString("");
    };
    return try allocCString(buffer[0..length]);
}

fn allocFormattedCString(comptime fmt: []const u8, args: anytype) ![*:0]u8 {
    const allocator = std.heap.c_allocator;
    const rendered = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(rendered);
    return try allocCString(rendered);
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
    // Note that Stockfish reports the C++ compiler via preprocessor macros (__clang__ / __GNUC__ /
    // _MSC_VER / ...). zfish compiles no C++ and is built by Zig (LLVM backend), so
    // report the Zig toolchain instead.
    return std.fmt.allocPrint(allocator, "Zig {s} (LLVM)", .{builtin.zig_version_string});
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
    // Report the Zig toolchain version, since the Zig build has no `__VERSION__`-style
    // compiler banner macro.
    return "Zig " ++ builtin.zig_version_string;
}

fn computeFallbackBuildDate() [8]u8 {
    // Recall this was derived from the C `__DATE__` macro. Treat build_options.git_date
    // (injected by build.zig) as the authoritative build date; Zig exposes no compile-time
    // date, so keep this fallback -- used only when git metadata is absent -- a fixed placeholder.
    return .{ '0', '0', '0', '0', '0', '0', '0', '0' };
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
    std.heap.c_allocator.free(std.mem.span(pointer));
    return owned;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Read the whole file the idiomatic-Zig way, replacing the libc fopen/fseek/ftell/fread/fclose
    // dance. Rely on `init_single_threaded`, a BLOCKING std.Io handle: it spawns no threads and
    // installs no signal handlers (`have_signal_handler = false`), so this startup read has
    // zero interaction with the engine's own threadpool. Collapse non-OOM failures to the
    // caller's existing FileOpenFailed, keeping the error set {FileOpenFailed, OutOfMemory}.
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.FileOpenFailed,
    };
}

fn isSpaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}
