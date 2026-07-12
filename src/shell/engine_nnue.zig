// Engine NNUE network lifecycle.
//
// The network verify / load / save operations, split out of engine.zig. These are
// the shared NNUE-load path that goEngine, perftEngine, and the eval trace all
// funnel through (verifyNetwork), so extracting them into a leaf breaks that
// cross-cluster coupling -- the trace cluster can then move out without reaching
// back into the engine core. Depends only on the network / option / uci_output
// modules + native_engine (for the engine-handle adapter, duplicated here); no
// import of engine, so no cycle. engine.zig re-exports the three (saveNetworkEngine
// is external port surface) and aliases printInfoStringNative for its option-apply
// code.

const std = @import("std");
const c = @import("libc");
const option_port = @import("option");
const network_port = @import("network");
const uci_output = @import("uci_output");
const native_engine = @import("native_engine");

pub fn printInfoStringNative(str: []const u8) void {
    var it = std.mem.splitScalar(u8, str, '\n');
    while (it.next()) |line| {
        var all_ws = true;
        for (line) |ch| {
            if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') {
                all_ws = false;
                break;
            }
        }
        if (all_ws) continue;
        var buf: [1024]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "info string {s}", .{line}) catch continue;
        uci_output.printLine(out.ptr, out.len);
    }
}

pub fn verifyNetwork() void {
    const evalfile_ptr = option_port.dupEvalFile() orelse return;
    defer std.heap.c_allocator.free(std.mem.span(evalfile_ptr));
    const evalfile = std.mem.span(evalfile_ptr);

    const result = network_port.verify(evalfile.ptr, evalfile.len);
    if (result.message) |message_ptr| {
        defer std.heap.c_allocator.free(std.mem.span(message_ptr));
        // onVerifyNetwork: interactive -> print as "info string ..."; quiet -> no-op.
        if (!uci_output.isQuiet()) printInfoStringNative(std.mem.span(message_ptr));
    }

    if (result.should_exit != 0) {
        c.exit(1);
    }
}

// Load a network from the given EvalFile path directly through the network module
// the engine owns the network pointer + binary directory, so no C-ABI round
// trip to main is needed. Mirrors the startup load in native_engine.constructMembers.
pub fn loadNetworkEngine(engine_ptr: *native_engine.NativeEngine, evalfile_path: []const u8) void {
    const e = engine_ptr;
    const bdir: [*:0]const u8 = e.binary_directory orelse "";
    const bdir_slice = std.mem.span(bdir);
    network_port.load(bdir_slice.ptr, bdir_slice.len, evalfile_path.ptr, evalfile_path.len);
}

pub fn saveNetworkEngine(filename_opt: ?[]const u8) void {
    const has_filename: u8 = if (filename_opt != null) 1 else 0;
    const filename = filename_opt orelse "";
    _ = network_port.save(has_filename, filename.ptr, filename.len);
}

test {
    @import("std").testing.refAllDecls(@This());
}
