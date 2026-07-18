// Control the engine runtime, split out of engine.zig: TT resize/clear plus the
// transposition-size / ponderhit / search-clear / hashfull entry points and
// their *Engine unwrappers. Operate on the ThreadPool / TranspositionTable /
// EngineObject graph through the tt/thread/option/tablebase ports. Duplicate
// freeCString here (a 3-line sentinel free) so the leaf needs no engine.zig
// import -- the edge stays one-way (engine.zig re-exports these).

const std = @import("std");
const worker_layout = @import("worker_layout");
const engine_object = @import("engine_object");
const tt_port = @import("tt");
const thread_port = @import("thread");
const option_port = @import("option");
const tablebase = @import("tablebase");

// Free a c_allocator-allocated NUL-terminated string through the Allocator
// interface (M-MEM.B), exact for these tightly-sized sentinel allocations.
fn freeCString(ptr: [*:0]u8) void {
    std.heap.c_allocator.free(std.mem.span(ptr));
}

fn ttResize(tt_ptr: *worker_layout.TranspositionTable, mb: usize, threads: *worker_layout.ThreadPool) void {
    const tp = tt_ptr;
    tt_port.resizeState(&tp.table, &tp.cluster_count, &tp.generation8, mb, threads);
}
fn ttClear(tt_ptr: *worker_layout.TranspositionTable, threads: *worker_layout.ThreadPool) void {
    const tp = tt_ptr;
    tt_port.clearState(tp.table, tp.cluster_count, &tp.generation8, threads);
}

pub fn setTtSize(threads: *worker_layout.ThreadPool, tt: *worker_layout.TranspositionTable, mb: usize) void {
    thread_port.waitThread(threads, 0);
    ttResize(tt, mb, threads);
}

pub fn setTtSizeEngine(engine_ptr: *engine_object.EngineObject, mb: usize) void {
    setTtSize(engine_ptr.threadsPtr(), engine_ptr.ttPtr(), mb);
}

pub fn setPonderhit(threads: *worker_layout.ThreadPool, ponder: u8) void {
    if (threads.mainManager()) |m| m.setPonder(ponder != 0);
}

pub fn setPonderhitEngine(engine_ptr: *engine_object.EngineObject, ponder: u8) void {
    setPonderhit(engine_ptr.threadsPtr(), ponder);
}

pub fn searchClear(threads: *worker_layout.ThreadPool, tt: *worker_layout.TranspositionTable, syzygy_path: []const u8) void {
    thread_port.waitForSearchFinished(threads);
    ttClear(tt, threads);
    thread_port.clear(threads);
    tablebase.init(syzygy_path.ptr, syzygy_path.len);
}

pub fn searchClearEngine(engine_ptr: *engine_object.EngineObject) void {
    // Borrow the model's own storage: setValue installs a new value before dispatching the
    // on-change callback, so a callback that lands here reads the installed one.
    searchClear(
        engine_ptr.threadsPtr(),
        engine_ptr.ttPtr(),
        option_port.strByName("SyzygyPath"),
    );
}

pub fn hashfullEngine(engine_ptr: *engine_object.EngineObject, max_age: i32) i32 {
    const tp = engine_ptr.ttPtr();
    const table = tp.table orelse return 0;
    return tt_port.hashfull(@ptrCast(@alignCast(table)), tp.cluster_count, tp.generation8, max_age);
}

pub fn stop(threads: *worker_layout.ThreadPool) void {
    threads.setStop(true);
}

pub fn stopEngine(engine_ptr: *engine_object.EngineObject) void {
    stop(engine_ptr.threadsPtr());
}

pub fn waitForSearchFinishedEngine(engine_ptr: *engine_object.EngineObject) void {
    thread_port.waitThread(engine_ptr.threadsPtr(), 0);
}

test {
    @import("std").testing.refAllDecls(@This());
}
