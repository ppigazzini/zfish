// Manage the engine NNUE network lifecycle.
//
// Provide the network verify / load / save operations, split out of engine.zig. Funnel
// goEngine, perftEngine, and the eval trace through the shared NNUE-load path
// (verifyNetwork), so extracting them into a leaf breaks that cross-cluster coupling --
// the trace cluster can then move out without reaching back into the engine core.
// Depend only on the network / option / uci_output modules + engine_object (for the
// engine-handle adapter, duplicated here); no import of engine, so no cycle. engine.zig
// re-exports the three (saveNetworkEngine is external port surface) and aliases
// printInfoString for its option-apply code.

const std = @import("std");
const c = @import("libc");
const option_port = @import("option");
const network_port = @import("network");
const uci_output = @import("uci_output");
const engine_object = @import("engine_object");

pub fn printInfoString(str: []const u8) void {
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

// Treat the external net as a RUNTIME input, not a build-time one: network.zig's
// embedded net is an unconditional 1-byte stub, so the real net must come from disk.
// `network.load` resolves EvalFile against the cwd and the binary directory, and
// reports nothing when every candidate misses. Worker construction then reads the
// feature-transformer biases (worker_construct.constructFull), which `orelse return`s
// on a null ftPtr and leaves the Worker zeroed -- so the miss first surfaces as a
// null shared_history in the clear job, on a worker thread, in an unrelated
// subsystem. Report it here instead, at the site that requires the net: name the
// file sought and every directory searched, and exit non-zero.
//
// Check ftPtr() -- it IS the contract constructFull needs.
// Write to stderr, not through uci_output: this is a fatal startup diagnostic, so
// it must not be swallowed by `Quiet` (a bench/parity run is quiet) nor depend on
// the output_sink hook being registered.
pub fn requireNetworkLoaded(engine_ptr: *engine_object.EngineObject) void {
    if (network_port.ftPtr() != null) return;

    const named = option_port.strByName("EvalFile");
    const evalfile: []const u8 = if (named.len != 0) named else network_port.default_eval_file_name;

    const bdir: [*:0]const u8 = engine_ptr.binary_directory orelse "";
    // Same cwd accessor misc.zig uses (its Io vtable wraps POSIX getcwd /
    // NT RtlGetCurrentDirectory); single-threaded blocking handle, no signal handlers.
    var threaded = std.Io.Threaded.init_single_threaded;
    var cwd_buf: [40000]u8 = undefined;
    const cwd: []const u8 = if (std.process.currentPath(threaded.io(), &cwd_buf)) |n|
        cwd_buf[0..n]
    else |_|
        "<unknown>";

    std.debug.print(
        \\ERROR: The network file {s} was not found.
        \\ERROR: Searched the current directory ({s}) and the binary directory ({s}).
        \\ERROR: The NNUE net is a required runtime input and is not embedded in this build.
        \\ERROR: Set the UCI option EvalFile to the full path of the network file, or run
        \\ERROR: the engine from a directory containing it.
        \\ERROR: The default net can be downloaded from: https://tests.stockfishchess.org/api/nn/{s}
        \\ERROR: The engine will be terminated now.
        \\
    , .{ evalfile, cwd, std.mem.span(bdir), network_port.default_eval_file_name });
    c.exit(1);
}

pub fn verifyNetwork() void {
    const evalfile = option_port.strByName("EvalFile");

    const result = network_port.verify(evalfile.ptr, evalfile.len);
    if (result.message) |message_ptr| {
        defer std.heap.c_allocator.free(std.mem.span(message_ptr));
        // Follow onVerifyNetwork: interactive -> print as "info string ..."; quiet -> no-op.
        if (!uci_output.isQuiet()) printInfoString(std.mem.span(message_ptr));
    }

    if (result.should_exit != 0) {
        c.exit(1);
    }
}

// Load a network from the given EvalFile path directly through the network module
// the engine owns the network pointer + binary directory, so no C-ABI round
// trip to main is needed. Mirror the startup load in engine_object.constructMembers.
pub fn loadNetworkEngine(engine_ptr: *engine_object.EngineObject, evalfile_path: []const u8) void {
    const e = engine_ptr;
    const bdir: [*:0]const u8 = e.binary_directory orelse "";
    const bdir_slice = std.mem.span(bdir);
    network_port.load(bdir_slice.ptr, bdir_slice.len, evalfile_path.ptr, evalfile_path.len);
}

// Report the outcome, as upstream does: `sync_cout << (saved ? "Network saved
// successfully to " + name : "Failed to export a net")` (nnue/network.cpp:133). save()
// already builds exactly that message -- the result was simply discarded with `_ =`, so
// `export_net` completed silently AND leaked the message allocMessage had built. Print it
// as a plain line (upstream does not prefix it with `info string`).
pub fn saveNetworkEngine(filename_opt: ?[]const u8) void {
    const has_filename: u8 = if (filename_opt != null) 1 else 0;
    const filename = filename_opt orelse "";
    const result = network_port.save(has_filename, filename.ptr, filename.len);
    if (result.message) |message_ptr| {
        defer std.heap.c_allocator.free(std.mem.span(message_ptr));
        const line = std.mem.span(message_ptr);
        uci_output.printLine(line.ptr, line.len);
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
