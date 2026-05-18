const std = @import("std");

const memory_port = @import("memory.zig");
const score_port = @import("score.zig");
const timeman_port = @import("timeman_rewrites");

extern fn zfish_main_run(argc: c_int, argv: [*]const [*:0]const u8) c_int;

pub fn main(init: std.process.Init) !void {
    var argc: usize = 0;
    var count_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (count_iter.next()) |_| {
        argc += 1;
    }

    const argv = try init.gpa.alloc([*:0]const u8, argc);
    defer init.gpa.free(argv);

    var fill_iter = std.process.Args.Iterator.init(init.minimal.args);
    var index: usize = 0;
    while (fill_iter.next()) |arg| : (index += 1) {
        argv[index] = arg.ptr;
    }

    const exit_code = zfish_main_run(@intCast(argc), argv.ptr);
    if (exit_code != 0) {
        std.process.exit(@intCast(exit_code));
    }
}

pub export fn zfish_std_aligned_alloc(alignment: usize, size: usize) ?*anyopaque {
    return memory_port.stdAlignedAlloc(alignment, size);
}

pub export fn zfish_std_aligned_free(ptr: ?*anyopaque) void {
    memory_port.stdAlignedFree(ptr);
}

pub export fn zfish_aligned_large_pages_alloc(alloc_size: usize) ?*anyopaque {
    return memory_port.alignedLargePagesAlloc(alloc_size);
}

pub export fn zfish_aligned_large_pages_free(ptr: ?*anyopaque) void {
    memory_port.alignedLargePagesFree(ptr);
}

pub export fn zfish_has_large_pages() bool {
    return memory_port.hasLargePages();
}

pub export fn zfish_classify_score(
    value: c_int,
    value_tb_win_in_max_ply: c_int,
    value_tb: c_int,
    value_mate: c_int,
) score_port.ScoreClass {
    return score_port.classify(value, value_tb_win_in_max_ply, value_tb, value_mate);
}

pub export fn zfish_timeman_init(
    input: timeman_port.TimemanInput,
) timeman_port.TimemanOutput {
    return timeman_port.init(input);
}
