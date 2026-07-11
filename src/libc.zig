//! Thin explicit libc binding -- the idiomatic-Zig replacement for the per-file `@cImport`
//! translate-C blocks (REPORT-16). Only the handful of C entry points the port still calls
//! are declared here, directly as `extern "c"`. Files that used
//! `const c = @cImport({ @cInclude("stdlib.h"); ... });` now `const c = @import("libc");`.
//!
//! The stdio surface (fopen/fread/fwrite/fgets/fprintf/puts/getcwd/...) has been retired:
//! file reads, stdout/stderr writes, the stdin command loop, and the cwd lookup all go
//! through std.Io now (`std.Io.Dir.readFileAlloc`, `std.Io.File.writeStreamingAll`, a
//! `std.Io` stdin reader, `std.process.currentPath`). What remains is genuinely libc:
//!   * malloc/free -- the C heap the graph allocator is layered on.
//!   * exit         -- process exit on a fatal parse error.
//!   * snprintf     -- ONLY the two float trace formats (`%6.2f`, `%+15.2f`). C's `%.2f`
//!                     rounds halves to even; std.fmt rounds them away, which would drift
//!                     the byte-exact eval-trace goldens, so these stay on libc until we
//!                     match glibc's round-half-to-even. Pointer params use precise Zig
//!                     types (`[*]u8`, `[*:0]const u8`) that are ABI-compatible with
//!                     `char*`, so there are zero C-pointer (translate-C) types in the tree.
//!
//! Compiler-detection preprocessor macros (`__GNUC__`, `__clang_*`, `__VERSION__`, ...) are
//! NOT here -- they have no libc symbol; misc.zig reports the Zig/LLVM build info instead.

// <stdlib.h>
pub extern "c" fn malloc(size: usize) ?*anyopaque;
pub extern "c" fn free(ptr: ?*anyopaque) void;
pub extern "c" fn exit(code: c_int) noreturn;
pub const EXIT_FAILURE: c_int = 1;

// <stdio.h> -- only snprintf survives, and only for the two float trace formats (see above).
pub extern "c" fn snprintf(str: [*]u8, size: usize, format: [*:0]const u8, ...) c_int;
