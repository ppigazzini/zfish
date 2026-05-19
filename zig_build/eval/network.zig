const std = @import("std");

const output_scale: c_int = 16;
const layer_stacks: usize = 8;
const internal_dir = "<internal>";

pub const ByteView = extern struct {
    ptr: [*]const u8,
    len: usize,
};

pub const SaveResult = extern struct {
    saved: u8,
    message: ?[*:0]u8,
};

pub const VerifyResult = extern struct {
    should_exit: u8,
    message: ?[*:0]u8,
};

pub const EvalOutput = extern struct {
    psqt: c_int,
    positional: c_int,
};

pub const VerifyInfo = extern struct {
    size_bytes: usize,
    input_dimensions: usize,
    transformed_dimensions: usize,
    fc0_outputs: c_int,
    fc1_outputs: c_int,
};

pub const TraceOutput = extern struct {
    psqt: [layer_stacks]c_int,
    positional: [layer_stacks]c_int,
    correct_bucket: usize,
};

extern fn zfish_network_default_name(network: *const anyopaque) ByteView;
extern fn zfish_network_current_name(network: *const anyopaque) ByteView;
extern fn zfish_network_load_user_net(
    network: *anyopaque,
    dir_ptr: [*]const u8,
    dir_len: usize,
    path_ptr: [*]const u8,
    path_len: usize,
) void;
extern fn zfish_network_load_internal(network: *anyopaque) void;
extern fn zfish_network_save_named(
    network: *const anyopaque,
    filename_ptr: [*]const u8,
    filename_len: usize,
) bool;
extern fn zfish_network_piece_count(pos: *const anyopaque) usize;
extern fn zfish_network_evaluate_bucket_raw(
    network: *const anyopaque,
    pos: *const anyopaque,
    accumulator_stack: *anyopaque,
    cache: *anyopaque,
    bucket: usize,
) EvalOutput;
extern fn zfish_network_verify_info(network: *const anyopaque) VerifyInfo;

pub fn load(
    network: *anyopaque,
    root_directory_ptr: [*]const u8,
    root_directory_len: usize,
    evalfile_path_ptr: [*]const u8,
    evalfile_path_len: usize,
) void {
    const root_directory = root_directory_ptr[0..root_directory_len];
    const default_name = viewToSlice(zfish_network_default_name(network));
    const evalfile_path = if (evalfile_path_len == 0)
        default_name
    else
        evalfile_path_ptr[0..evalfile_path_len];
    const dirs = [_][]const u8{ internal_dir, "", root_directory };

    for (dirs) |directory| {
        if (!equalCurrentName(network, evalfile_path)) {
            if (!std.mem.eql(u8, directory, internal_dir)) {
                zfish_network_load_user_net(network, directory.ptr, directory.len, evalfile_path.ptr, evalfile_path.len);
            }

            if (std.mem.eql(u8, directory, internal_dir) and std.mem.eql(u8, evalfile_path, default_name)) {
                zfish_network_load_internal(network);
            }
        }
    }
}

pub fn save(
    network: *const anyopaque,
    has_filename: u8,
    filename_ptr: [*]const u8,
    filename_len: usize,
) SaveResult {
    const default_name = viewToSlice(zfish_network_default_name(network));
    const current_name = viewToSlice(zfish_network_current_name(network));

    var actual_filename: []const u8 = undefined;
    if (has_filename != 0) {
        actual_filename = filename_ptr[0..filename_len];
    } else {
        if (!std.mem.eql(u8, current_name, default_name)) {
            return .{
                .saved = 0,
                .message = allocMessage(
                    "Failed to export a net. A non-embedded net can only be saved if the filename is specified",
                    .{},
                ),
            };
        }

        actual_filename = default_name;
    }

    const saved = zfish_network_save_named(network, actual_filename.ptr, actual_filename.len);
    return .{
        .saved = boolToU8(saved),
        .message = if (saved)
            allocMessage("Network saved successfully to {s}", .{actual_filename})
        else
            allocMessage("Failed to export a net", .{}),
    };
}

pub fn verify(
    network: *const anyopaque,
    evalfile_path_ptr: [*]const u8,
    evalfile_path_len: usize,
) VerifyResult {
    const default_name = viewToSlice(zfish_network_default_name(network));
    const current_name = viewToSlice(zfish_network_current_name(network));
    const evalfile_path = if (evalfile_path_len == 0)
        default_name
    else
        evalfile_path_ptr[0..evalfile_path_len];

    if (!std.mem.eql(u8, current_name, evalfile_path)) {
        return .{
            .should_exit = 1,
            .message = allocMessage(
                "ERROR: Network evaluation parameters compatible with the engine must be available.\n" ++
                    "ERROR: The network file {s} was not loaded successfully.\n" ++
                    "ERROR: The UCI option EvalFile might need to specify the full path, including the directory name, to the network file.\n" ++
                    "ERROR: The default net can be downloaded from: https://tests.stockfishchess.org/api/nn/{s}\n" ++
                    "ERROR: The engine will be terminated now.\n",
                .{ evalfile_path, default_name },
            ),
        };
    }

    const info = zfish_network_verify_info(network);
    return .{
        .should_exit = 0,
        .message = allocMessage(
            "NNUE evaluation using {s} ({d}MiB, ({d}, {d}, {d}, {d}, 1))",
            .{
                evalfile_path,
                info.size_bytes / (1024 * 1024),
                info.input_dimensions,
                info.transformed_dimensions,
                info.fc0_outputs,
                info.fc1_outputs,
            },
        ),
    };
}

pub fn evaluate(
    network: *const anyopaque,
    pos: *const anyopaque,
    accumulator_stack: *anyopaque,
    cache: *anyopaque,
) EvalOutput {
    const piece_count = zfish_network_piece_count(pos);
    const bucket = (piece_count - 1) / 4;
    const raw = zfish_network_evaluate_bucket_raw(network, pos, accumulator_stack, cache, bucket);
    return .{
        .psqt = @divTrunc(raw.psqt, output_scale),
        .positional = @divTrunc(raw.positional, output_scale),
    };
}

pub fn traceEvaluate(
    network: *const anyopaque,
    pos: *const anyopaque,
    accumulator_stack: *anyopaque,
    cache: *anyopaque,
) TraceOutput {
    var output = TraceOutput{
        .psqt = [_]c_int{0} ** layer_stacks,
        .positional = [_]c_int{0} ** layer_stacks,
        .correct_bucket = 0,
    };
    const piece_count = zfish_network_piece_count(pos);
    output.correct_bucket = (piece_count - 1) / 4;

    var bucket: usize = 0;
    while (bucket < layer_stacks) : (bucket += 1) {
        const raw = zfish_network_evaluate_bucket_raw(network, pos, accumulator_stack, cache, bucket);
        output.psqt[bucket] = @divTrunc(raw.psqt, output_scale);
        output.positional[bucket] = @divTrunc(raw.positional, output_scale);
    }

    return output;
}

fn viewToSlice(view: ByteView) []const u8 {
    return view.ptr[0..view.len];
}

fn equalCurrentName(network: *const anyopaque, target: []const u8) bool {
    return std.mem.eql(u8, viewToSlice(zfish_network_current_name(network)), target);
}

fn boolToU8(value: bool) u8 {
    return if (value) 1 else 0;
}

fn allocMessage(comptime fmt: []const u8, args: anytype) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const rendered = std.fmt.allocPrint(allocator, fmt, args) catch return null;
    defer allocator.free(rendered);
    const owned = allocator.allocSentinel(u8, rendered.len, 0) catch return null;
    @memcpy(owned[0..rendered.len], rendered);
    return owned.ptr;
}
