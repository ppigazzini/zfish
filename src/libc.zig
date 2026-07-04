//! Thin explicit libc binding -- the idiomatic-Zig replacement for the per-file `@cImport`
//! translate-C blocks (REPORT-16). One opaque `FILE` type plus the C stdio/stdlib/sys-time
//! entry points the port actually calls, declared directly as `extern "c"`. Files that used
//! `const c = @cImport({ @cInclude("stdio.h"); ... });` now `const c = @import("libc");` with
//! their `c.<name>` call sites unchanged. Benefits over @cImport: no translate-C step, no
//! host-header dependency (so macOS cross-compiles from Linux), and one shared `FILE` type
//! instead of a distinct per-cImport one. Pointer params use the liberal C-pointer type
//! (`[*c]`) so the existing call sites coerce exactly as they did under translate-C.
//!
//! Compiler-detection preprocessor macros (`__GNUC__`, `__clang_*`, `__VERSION__`, ...) are
//! NOT here -- they have no libc symbol; misc.zig reports the Zig/LLVM build info instead.

// An incomplete C `FILE` -- only ever handled behind a pointer.
pub const FILE = opaque {};

// <stdlib.h>
pub extern "c" fn malloc(size: usize) ?*anyopaque;
pub extern "c" fn free(ptr: ?*anyopaque) void;
pub extern "c" fn exit(code: c_int) noreturn;
pub const EXIT_FAILURE: c_int = 1;

// <stdio.h>
pub extern "c" fn fopen(path: [*c]const u8, mode: [*c]const u8) ?*FILE;
pub extern "c" fn fclose(stream: ?*FILE) c_int;
pub extern "c" fn fread(ptr: ?*anyopaque, size: usize, nmemb: usize, stream: ?*FILE) usize;
pub extern "c" fn fwrite(ptr: ?*const anyopaque, size: usize, nmemb: usize, stream: ?*FILE) usize;
pub extern "c" fn fputc(ch: c_int, stream: ?*FILE) c_int;
pub extern "c" fn fflush(stream: ?*FILE) c_int;
pub extern "c" fn fgets(str: [*c]u8, n: c_int, stream: ?*FILE) [*c]u8;
pub extern "c" fn fprintf(stream: ?*FILE, format: [*c]const u8, ...) c_int;
pub extern "c" fn puts(str: [*c]const u8) c_int;
pub extern "c" fn snprintf(str: [*c]u8, size: usize, format: [*c]const u8, ...) c_int;
pub extern "c" fn fseek(stream: ?*FILE, offset: c_long, whence: c_int) c_int;
pub extern "c" fn ftell(stream: ?*FILE) c_long;
pub extern "c" fn ferror(stream: ?*FILE) c_int;
pub const SEEK_SET: c_int = 0;
pub const SEEK_END: c_int = 2;

// <sys/time.h>. Field names match the translate-C `struct_timeval` the call sites read.
pub const struct_timeval = extern struct {
    tv_sec: c_long,
    tv_usec: c_long,
};
pub extern "c" fn gettimeofday(tv: *struct_timeval, tz: ?*anyopaque) c_int;
