// Terminate the process on a critical command failure.
//
// Own upstream's UCIEngine::terminate_on_critical_error (uci.cpp:684) and the
// `currentCmd` it echoes (uci.cpp:102). Split out of uci.zig as a file import (the
// uci_bench.zig pattern): the dispatch loop is at the god-file limit, and this is a
// self-contained cluster -- the command being dispatched, plus the one path that reports
// and exits. Depend only on the format/output/string leaves uci.zig already imports, and
// never import uci.zig back, so no file cycle.

const std = @import("std");
const uci_format = @import("uci_format");
const uci_output = @import("uci_output");
const uci_strings = @import("uci_strings");

// Hold the command line being dispatched so the error path can echo it whole, as
// upstream's `currentCmd = cmd` does -- hence ``Command `position fen not_a_fen` failed``
// rather than ``Command `position` ``. The UCI listener is single-threaded, so a plain
// global matches upstream's member.
var current_cmd: []const u8 = "";

pub fn setCurrentCmd(cmd: []const u8) void {
    current_cmd = cmd;
}

// Report the failure and exit(1), mirroring upstream. A failed command must not leave the
// engine running: printing and continuing left the PREVIOUS position live, so the next
// `go` searched a stale board and answered with a plausible bestmove for the wrong
// position. Route the line through the output sink (stdout + `Debug Log File` tee).
pub fn terminateOnCriticalError(message: []const u8) noreturn {
    if (uci_format.formatCriticalError(current_cmd, message)) |ptr| {
        defer uci_strings.freeMaybeCString(ptr);
        const line = std.mem.span(ptr);
        uci_output.printLine(line.ptr, line.len);
    }
    std.process.exit(1);
}

test {
    @import("std").testing.refAllDecls(@This());
}
