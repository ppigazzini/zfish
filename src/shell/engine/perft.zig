// Drive engine perft.
//
// Divide the `go perft N` root, split out of engine.zig. Now that verifyNetwork and
// fen live in leaves (engine_nnue / engine_trace), perft's only remaining
// couplings are those two plus the ne() handle adapter -- all leaf-reachable -- so
// it extracts cleanly with no cycle. engine.zig re-exports perftEngine (called by
// uci `go perft`).

const std = @import("std");
const worker_layout = @import("worker_layout");
const movegen_port = @import("movegen");
const position_port = @import("position");
const option_port = @import("option");
const uci_move = @import("uci_move");
const uci_output = @import("uci_output");
const engine_object = @import("engine_object");
const engine_nnue = @import("engine_nnue");
const engine_trace = @import("engine_trace");

const verifyNetwork = engine_nnue.verifyNetwork;
const fen = engine_trace.fen;

const perft_max_depth = 64;
const PerftStateBuf = position_port.StateInfo;

fn perftCount(pos_ptr: *position_port.Position, depth: c_int, states: *[perft_max_depth]PerftStateBuf, ply: usize) u64 {
    if (depth <= 0) return 1;
    var moves: [256]u16 = undefined;
    const n = movegen_port.generateLegal(pos_ptr, &moves);
    if (depth == 1) return n;
    var nodes: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        position_port.doMoveState(pos_ptr, moves[i], &states[ply]);
        nodes += perftCount(pos_ptr, depth - 1, states, ply + 1);
        position_port.undoMove(pos_ptr, moves[i]);
    }
    return nodes;
}

fn perftSubtree(pos_ptr: *position_port.Position, depth: c_int) u64 {
    const capped = if (depth > perft_max_depth) perft_max_depth else depth;
    var states: [perft_max_depth]PerftStateBuf align(64) = undefined;
    return perftCount(pos_ptr, capped, &states, 0);
}

// Report the position error alongside the node count, mirroring upstream's
// `std::variant<u64, PositionSetError> Engine::perft(...)` (engine.h:63). The error from
// setPosition was freed and discarded here, and perft then ran over a Position that had
// not been populated. Callers terminate on `err`, as upstream's uci.cpp:478 does.
pub const PerftResult = struct {
    nodes: u64 = 0,
    err: ?[*:0]u8 = null,
};

pub fn perftEngine(engine_ptr: *engine_object.EngineObject, depth: c_int) PerftResult {
    verifyNetwork();
    const fen_ptr = fen(engine_ptr.positionPtr()) orelse @panic("perft: null fen");
    const fen_text = std.mem.span(fen_ptr);
    const chess960 = option_port.intByName("UCI_Chess960") != 0;

    // Allocate scope-local Position/StateInfo via the Allocator interface (c_allocator
    // keeps the libc backing, so lifetimes are valgrind-identical) + defer cleanup +
    // typed create (no @ptrCast, no @memset). @sizeOf == the pinned slot size.
    const allocator = std.heap.c_allocator;
    // Treat `go perft` as a debug command -- on OOM report 0 nodes rather than aborting.
    const p = allocator.create(position_port.Position) catch return .{};
    defer allocator.destroy(p);
    const st = allocator.create(position_port.StateInfo) catch return .{};
    defer allocator.destroy(st);
    // Zero via @memset (not std.mem.zeroes): Position/StateInfo carry non-null pointer
    // fields, so byte-zero-then-setPosition-populate is the (existing) init contract.
    @memset(@as([*]u8, @ptrCast(p))[0..@sizeOf(position_port.Position)], 0);
    @memset(@as([*]u8, @ptrCast(st))[0..@sizeOf(position_port.StateInfo)], 0);
    // Surface the parse failure instead of freeing it and perfting an unpopulated board.
    if (position_port.setPosition(p, fen_text.ptr, fen_text.len, if (chess960) @as(u8, 1) else 0, st, worker_layout.position_size, worker_layout.state_info_size)) |msg|
        return .{ .err = msg };

    var moves: [256]u16 = undefined;
    const count = movegen_port.generateLegal(p, &moves);
    var nodes: u64 = 0;
    var mbuf: [5]u8 = undefined;
    var line: [64]u8 = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const m = moves[i];
        var cnt: u64 = undefined;
        if (depth <= 1) {
            cnt = 1;
            nodes += 1;
        } else {
            var si: position_port.StateInfo = undefined;
            position_port.doMoveState(p, m, &si);
            cnt = perftSubtree(p, depth - 1);
            nodes += cnt;
            position_port.undoMove(p, m);
        }
        const txt = uci_move.renderMoveText(&mbuf, m, chess960);
        const out = std.fmt.bufPrint(&line, "{s}: {d}", .{ txt, cnt }) catch unreachable;
        uci_output.printLine(out.ptr, out.len);
    }

    std.heap.c_allocator.free(std.mem.span(fen_ptr));

    var nbuf: [64]u8 = undefined;
    const nout = std.fmt.bufPrint(&nbuf, "\nNodes searched: {d}\n", .{nodes}) catch unreachable;
    uci_output.printLine(nout.ptr, nout.len);
    return .{ .nodes = nodes };
}
