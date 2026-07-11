//! Thin explicit libc binding -- the idiomatic-Zig replacement for the per-file `@cImport`
//! translate-C blocks (REPORT-16). One opaque `FILE` type plus the C stdio/stdlib/sys-time
//! entry points the port actually calls, declared directly as `extern "c"`. Files that used
//! `const c = @cImport({ @cInclude("stdio.h"); ... });` now `const c = @import("libc");` with
//! their `c.<name>` call sites unchanged. Benefits over @cImport: no translate-C step, no
//! host-header dependency (so macOS cross-compiles from Linux), and one shared `FILE` type
//! instead of a distinct per-cImport one. Pointer params use PRECISE Zig pointer types
//! (`[*:0]const u8` C-strings, `[*]u8` out-buffers, `?[*:0]u8` char*-or-NULL returns) that
//! are ABI-compatible with `char*` -- so there are zero C-pointer (translate-C) types in the
//! tree while the call sites still coerce. These are the genuine libc syscall boundary; wider
//! stdio (puts/fprintf/fgets/fopen) is a future std.Io migration (blocked on adopting Zig
//! 0.16's dependency-injected `Io` interface engine-wide -- a large, golden-sensitive port).
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
pub extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
pub extern "c" fn fclose(stream: ?*FILE) c_int;
pub extern "c" fn fread(ptr: ?*anyopaque, size: usize, nmemb: usize, stream: ?*FILE) usize;
pub extern "c" fn fwrite(ptr: ?*const anyopaque, size: usize, nmemb: usize, stream: ?*FILE) usize;
pub extern "c" fn fputc(ch: c_int, stream: ?*FILE) c_int;
pub extern "c" fn fflush(stream: ?*FILE) c_int;
pub extern "c" fn fgets(str: [*]u8, n: c_int, stream: ?*FILE) ?[*:0]u8;
pub extern "c" fn fprintf(stream: ?*FILE, format: [*:0]const u8, ...) c_int;
pub extern "c" fn puts(str: [*:0]const u8) c_int;
pub extern "c" fn snprintf(str: [*]u8, size: usize, format: [*:0]const u8, ...) c_int;
pub extern "c" fn fseek(stream: ?*FILE, offset: c_long, whence: c_int) c_int;
pub extern "c" fn ftell(stream: ?*FILE) c_long;
pub extern "c" fn ferror(stream: ?*FILE) c_int;
pub const SEEK_SET: c_int = 0;
pub const SEEK_END: c_int = 2;

// <unistd.h>
pub extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
