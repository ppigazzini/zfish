const std = @import("std");

const benchmark_port = @import("benchmark_rewrites");
const memory_port = @import("memory.zig");
const misc_port = @import("misc_rewrites");
const score_port = @import("score.zig");
const evaluate_port = @import("evaluate_rewrites");
const nnue_misc_port = @import("nnue_misc_rewrites");
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

pub export fn zfish_misc_hash_bytes(
    data_ptr: [*]const u8,
    data_len: usize,
) u64 {
    return misc_port.hashBytes(data_ptr[0..data_len]);
}

pub export fn zfish_misc_str_to_size_t(
    input_ptr: [*]const u8,
    input_len: usize,
) usize {
    return misc_port.strToSizeT(input_ptr[0..input_len]);
}

pub export fn zfish_misc_read_file_to_string(
    path_ptr: [*]const u8,
    path_len: usize,
) ?[*:0]u8 {
    return misc_port.readFileToString(path_ptr[0..path_len]);
}

pub export fn zfish_misc_remove_whitespace(
    input_ptr: [*]const u8,
    input_len: usize,
) ?[*:0]u8 {
    return misc_port.removeWhitespace(input_ptr[0..input_len]);
}

pub export fn zfish_misc_is_whitespace(
    input_ptr: [*]const u8,
    input_len: usize,
) bool {
    return misc_port.isWhitespace(input_ptr[0..input_len]);
}

pub export fn zfish_misc_get_binary_directory(
    argv0_ptr: [*]const u8,
    argv0_len: usize,
) ?[*:0]u8 {
    return misc_port.getBinaryDirectory(argv0_ptr[0..argv0_len]);
}

pub export fn zfish_misc_get_working_directory() ?[*:0]u8 {
    return misc_port.getWorkingDirectory();
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

pub export fn zfish_eval_compute_value(
    input: evaluate_port.EvalInput,
) c_int {
    return evaluate_port.computeValue(input);
}

pub export fn zfish_eval_format_trace(
    input: evaluate_port.EvalTraceInput,
) ?[*:0]u8 {
    return evaluate_port.formatTrace(input);
}

pub export fn zfish_nnue_format_trace(
    input: nnue_misc_port.NnueTraceInput,
) ?[*:0]u8 {
    return nnue_misc_port.formatTrace(input);
}

pub export fn zfish_benchmark_setup_bench(
    current_fen_ptr: [*]const u8,
    current_fen_len: usize,
    args_ptr: [*]const u8,
    args_len: usize,
) ?[*:0]u8 {
    return benchmark_port.setupBench(
        current_fen_ptr[0..current_fen_len],
        args_ptr[0..args_len],
    );
}

pub export fn zfish_benchmark_setup_benchmark(
    args_ptr: [*]const u8,
    args_len: usize,
    hardware_concurrency: c_int,
) benchmark_port.BenchmarkSetupOutput {
    return benchmark_port.setupBenchmark(args_ptr[0..args_len], hardware_concurrency);
}
