const builtin = @import("builtin");
const build_options = @import("build_options");
const std = @import("std");
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

pub fn getBinaryDirectory(gpa: std.mem.Allocator, argv0: []const u8) ?[]u8 {
    return getBinaryDirectoryAlloc(gpa, argv0) catch null;
}

// The three banner renderers hand back an owned SLICE; the caller frees it with the
// allocator it passed in.

pub fn engineVersionInfoText(gpa: std.mem.Allocator) ?[]u8 {
    return engineVersionOwned(gpa) catch null;
}

pub fn engineInfoText(gpa: std.mem.Allocator, to_uci: bool) ?[]u8 {
    const version_text = engineVersionOwned(gpa) catch return null;
    defer gpa.free(version_text);

    return std.fmt.allocPrint(
        gpa,
        "{s}{s}the Stockfish developers (see AUTHORS file)",
        .{ version_text, if (to_uci) "\nid author " else " by " },
    ) catch null;
}

pub fn compilerInfoText(gpa: std.mem.Allocator) ?[]u8 {
    const compiler_name = compilerNameOwned(gpa) catch return null;
    defer gpa.free(compiler_name);
    const settings = compilationSettingsOwned(gpa) catch return null;
    defer gpa.free(settings);

    return std.fmt.allocPrint(
        gpa,
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

pub fn hardwareConcurrency() i32 {
    // Return the number of hardware threads (Stockfish's get_hardware_concurrency).
    // Use std.Thread.getCpuCount(), the cross-platform equivalent -- sysconf(_SC_NPROCESSORS_ONLN)
    // on POSIX, GetSystemInfo on Windows -- so it matches the prior Linux glibc behavior while
    // also working on the owned Windows/macOS tiers. Clamp an error to 0.
    const n = std.Thread.getCpuCount() catch return 0;
    return std.math.cast(i32, n) orelse 0;
}

fn getBinaryDirectoryAlloc(gpa: std.mem.Allocator, argv0: []const u8) ![]u8 {
    const allocator = gpa;
    const path_separator = "/";
    const working_directory = try getWorkingDirectoryAlloc(allocator);
    defer allocator.free(working_directory);

    var binary_directory = std.ArrayList(u8).empty;
    errdefer binary_directory.deinit(allocator);
    try binary_directory.appendSlice(allocator, argv0);

    const separator_index = std.mem.findLastAny(u8, binary_directory.items, "\\/");
    if (separator_index) |index| {
        binary_directory.shrinkRetainingCapacity(index + 1);
    } else {
        binary_directory.clearRetainingCapacity();
        try binary_directory.appendSlice(allocator, ".");
        try binary_directory.appendSlice(allocator, path_separator);
    }

    if (std.mem.startsWith(u8, binary_directory.items, "." ++ path_separator)) {
        var resolved = std.ArrayList(u8).empty;
        errdefer resolved.deinit(allocator);
        try resolved.appendSlice(allocator, working_directory);
        try resolved.appendSlice(allocator, binary_directory.items[1..]);
        return try resolved.toOwnedSlice(allocator);
    }

    return try binary_directory.toOwnedSlice(allocator);
}

fn getWorkingDirectoryAlloc(gpa: std.mem.Allocator) ![]u8 {
    // Look up the cwd the idiomatic-Zig way, replacing libc getcwd. Use std.process.currentPath,
    // the cross-platform accessor (its Io vtable wraps POSIX getcwd / NT RtlGetCurrentDirectory);
    // rely on `init_single_threaded`, the same blocking, no-thread, no-signal-handler handle used
    // for the net-file read. On any failure keep the original "" fallback.
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var buffer: [40000]u8 = undefined;
    const length = std.process.currentPath(io, &buffer) catch {
        return try gpa.dupe(u8, "");
    };
    return try gpa.dupe(u8, buffer[0..length]);
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
