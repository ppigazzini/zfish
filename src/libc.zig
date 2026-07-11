//! Thin explicit libc binding -- the idiomatic-Zig replacement for the per-file `@cImport`
//! translate-C blocks (REPORT-16). Only the handful of C entry points the port still calls
//! are declared here, directly as `extern "c"`. Files that used
//! `const c = @cImport({ @cInclude("stdlib.h"); ... });` now `const c = @import("libc");`.
//!
//! The entire stdio surface has been retired -- fopen/fread/fwrite/fgets/fprintf/puts/
//! snprintf/getcwd all gone. File reads, stdout/stderr writes, the stdin command loop, the
//! cwd lookup, and every numeric/float trace format now go through std.Io / std.fmt
//! (`std.Io.Dir.readFileAlloc`, `std.Io.File.writeStreamingAll`, a `std.Io` stdin reader,
//! `std.process.currentPath`, `std.fmt.bufPrint`). The float trace formats moved last: they
//! are only ever `centipawns*0.01`, values on the 2-decimal grid, so C's round-half-to-even
//! and std.fmt's round-half-away can never disagree (proven byte-exact over cp in +-2e6).
//!
//! What remains is genuinely libc, not stdio:
//!   * malloc/free -- the C heap the graph allocator is layered on.
//!   * exit         -- process exit on a fatal parse error.
//!
//! Compiler-detection preprocessor macros (`__GNUC__`, `__clang_*`, `__VERSION__`, ...) are
//! NOT here -- they have no libc symbol; misc.zig reports the Zig/LLVM build info instead.

// <stdlib.h>
pub extern "c" fn malloc(size: usize) ?*anyopaque;
pub extern "c" fn free(ptr: ?*anyopaque) void;
pub extern "c" fn exit(code: c_int) noreturn;
pub const EXIT_FAILURE: c_int = 1;
