const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});

const output_scale: c_int = 16;
const layer_stacks: usize = 8;
const internal_dir = "<internal>";
const cache_line_size: usize = 64;
const transformed_feature_bytes: usize = 1024;
const square_count: usize = 64;
const no_piece: u8 = 0;
const network_version: u32 = 0x7AF32F20;
const hash_combine_magic: usize = 0x9e3779b9;
const none_name = "None";

pub const ByteView = extern struct {
    ptr: [*]const u8,
    len: usize,
};

pub const OwnedByteView = extern struct {
    ptr: ?[*]const u8,
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
extern fn zfish_network_description(network: *const anyopaque) ByteView;
extern fn zfish_network_embedded_bytes() ByteView;
extern fn zfish_network_mark_initialized(network: *anyopaque) void;
extern fn zfish_network_set_loaded_state(
    network: *anyopaque,
    current_name_ptr: [*]const u8,
    current_name_len: usize,
    description_ptr: [*]const u8,
    description_len: usize,
) void;
extern fn zfish_network_is_initialized(network: *const anyopaque) bool;
extern fn zfish_network_hash_value() u32;
extern fn zfish_network_feature_transformer_read_blob(
    network: *anyopaque,
    data_ptr: [*]const u8,
    data_len: usize,
) usize;
extern fn zfish_network_layer_read_blob(
    network: *anyopaque,
    bucket: usize,
    data_ptr: [*]const u8,
    data_len: usize,
) usize;
extern fn zfish_network_feature_transformer_write_blob(network: *const anyopaque) OwnedByteView;
extern fn zfish_network_layer_write_blob(network: *const anyopaque, bucket: usize) OwnedByteView;
extern fn zfish_network_feature_transformer_content_hash(network: *const anyopaque) usize;
extern fn zfish_network_layer_content_hash(network: *const anyopaque, bucket: usize) usize;
extern fn zfish_network_eval_file_content_hash(network: *const anyopaque) usize;
extern fn zfish_accumulator_position_snapshot(pos: *const anyopaque, pieces_out: [*]u8) void;
extern fn zfish_network_transform_bucket(
    network: *const anyopaque,
    pos: *const anyopaque,
    accumulator_stack: *anyopaque,
    cache: *anyopaque,
    bucket: usize,
    transformed_ptr: [*]u8,
) c_int;
extern fn zfish_network_propagate_bucket(
    network: *const anyopaque,
    bucket: usize,
    transformed_ptr: [*]const u8,
) c_int;
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
                loadUserNet(network, directory, evalfile_path);
            }

            if (std.mem.eql(u8, directory, internal_dir) and std.mem.eql(u8, evalfile_path, default_name)) {
                loadInternal(network);
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

    const saved = saveNamed(network, actual_filename);
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
    const piece_count = pieceCount(pos);
    const bucket = (piece_count - 1) / 4;
    const raw = evaluateBucketRaw(network, pos, accumulator_stack, cache, bucket);
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
    const piece_count = pieceCount(pos);
    output.correct_bucket = (piece_count - 1) / 4;

    var bucket: usize = 0;
    while (bucket < layer_stacks) : (bucket += 1) {
        const raw = evaluateBucketRaw(network, pos, accumulator_stack, cache, bucket);
        output.psqt[bucket] = @divTrunc(raw.psqt, output_scale);
        output.positional[bucket] = @divTrunc(raw.positional, output_scale);
    }

    return output;
}

pub fn contentHash(network: *const anyopaque) usize {
    if (!zfish_network_is_initialized(network)) {
        return 0;
    }

    var hash: usize = 0;
    hashCombine(&hash, zfish_network_feature_transformer_content_hash(network));

    var bucket: usize = 0;
    while (bucket < layer_stacks) : (bucket += 1) {
        hashCombine(&hash, zfish_network_layer_content_hash(network, bucket));
    }

    hashCombine(&hash, zfish_network_eval_file_content_hash(network));
    return hash;
}

fn evaluateBucketRaw(
    network: *const anyopaque,
    pos: *const anyopaque,
    accumulator_stack: *anyopaque,
    cache: *anyopaque,
    bucket: usize,
) EvalOutput {
    var transformed: [transformed_feature_bytes]u8 align(cache_line_size) = undefined;

    return .{
        .psqt = zfish_network_transform_bucket(
            network,
            pos,
            accumulator_stack,
            cache,
            bucket,
            @ptrCast(&transformed),
        ),
        .positional = zfish_network_propagate_bucket(network, bucket, @ptrCast(&transformed)),
    };
}

fn pieceCount(pos: *const anyopaque) usize {
    var pieces = [_]u8{0} ** square_count;
    zfish_accumulator_position_snapshot(pos, @ptrCast(&pieces));

    var count: usize = 0;
    for (pieces) |piece| {
        if (piece != no_piece) {
            count += 1;
        }
    }

    return count;
}

const Header = struct {
    hash_value: u32,
    description: []const u8,
};

fn loadUserNet(network: *anyopaque, dir: []const u8, evalfile_path: []const u8) void {
    zfish_network_mark_initialized(network);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    const io = threaded.io();

    const path = std.mem.concat(arena, u8, &.{ dir, evalfile_path }) catch return;
    const file = openFileForRead(io, path) catch return;
    defer file.close(io);

    const stat = file.stat(io) catch return;
    var reader_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);

    const bytes = reader.interface.readAlloc(arena, stat.size) catch return;
    _ = loadNetworkBytes(network, bytes, evalfile_path);
}

fn loadInternal(network: *anyopaque) void {
    zfish_network_mark_initialized(network);

    const default_name = viewToSlice(zfish_network_default_name(network));
    _ = loadNetworkBytes(network, viewToSlice(zfish_network_embedded_bytes()), default_name);
}

fn saveNamed(network: *const anyopaque, filename: []const u8) bool {
    const current_name = viewToSlice(zfish_network_current_name(network));
    if (current_name.len == 0 or std.mem.eql(u8, current_name, none_name)) {
        return false;
    }

    const description = viewToSlice(zfish_network_description(network));
    var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    const io = threaded.io();
    const file = openFileForWrite(io, filename) catch return false;
    defer file.close(io);
    var writer_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &writer_buffer);

    writeHeader(&writer.interface, zfish_network_hash_value(), description) catch return false;
    writeOwnedBlob(&writer.interface, zfish_network_feature_transformer_write_blob(network)) catch return false;

    var bucket: usize = 0;
    while (bucket < layer_stacks) : (bucket += 1) {
        writeOwnedBlob(&writer.interface, zfish_network_layer_write_blob(network, bucket)) catch return false;
    }

    writer.interface.flush() catch return false;

    return true;
}

fn loadNetworkBytes(network: *anyopaque, bytes: []const u8, current_name: []const u8) bool {
    var offset: usize = 0;
    const header = readHeader(bytes, &offset) orelse return false;
    if (header.hash_value != zfish_network_hash_value()) {
        return false;
    }

    if (!readFeatureTransformer(network, bytes, &offset)) {
        return false;
    }

    var bucket: usize = 0;
    while (bucket < layer_stacks) : (bucket += 1) {
        if (!readLayer(network, bucket, bytes, &offset)) {
            return false;
        }
    }

    if (offset != bytes.len) {
        return false;
    }

    zfish_network_set_loaded_state(
        network,
        current_name.ptr,
        current_name.len,
        header.description.ptr,
        header.description.len,
    );
    return true;
}

fn readHeader(bytes: []const u8, offset: *usize) ?Header {
    const version = readU32Le(bytes, offset) orelse return null;
    const hash_value = readU32Le(bytes, offset) orelse return null;
    const description_len_u32 = readU32Le(bytes, offset) orelse return null;
    if (version != network_version) {
        return null;
    }

    const description_len: usize = @intCast(description_len_u32);
    if (offset.* + description_len > bytes.len) {
        return null;
    }

    const description = bytes[offset.* .. offset.* + description_len];
    offset.* += description_len;
    return .{ .hash_value = hash_value, .description = description };
}

fn readFeatureTransformer(network: *anyopaque, bytes: []const u8, offset: *usize) bool {
    const remaining = bytes[offset.*..];
    const consumed = zfish_network_feature_transformer_read_blob(network, remaining.ptr, remaining.len);
    if (consumed == 0 or consumed > remaining.len) {
        return false;
    }
    offset.* += consumed;
    return true;
}

fn readLayer(network: *anyopaque, bucket: usize, bytes: []const u8, offset: *usize) bool {
    const remaining = bytes[offset.*..];
    const consumed = zfish_network_layer_read_blob(network, bucket, remaining.ptr, remaining.len);
    if (consumed == 0 or consumed > remaining.len) {
        return false;
    }
    offset.* += consumed;
    return true;
}

fn openFileForRead(io: std.Io, path: []const u8) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openFileAbsolute(io, path, .{});
    }

    return std.Io.Dir.cwd().openFile(io, path, .{});
}

fn openFileForWrite(io: std.Io, path: []const u8) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    }

    return std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
}

fn writeHeader(writer: *std.Io.Writer, hash_value: u32, description: []const u8) !void {
    var header = [_]u8{0} ** 12;
    writeU32LeInto(header[0..4], network_version);
    writeU32LeInto(header[4..8], hash_value);
    writeU32LeInto(header[8..12], @intCast(description.len));
    try writer.writeAll(&header);
    try writer.writeAll(description);
}

fn writeOwnedBlob(writer: *std.Io.Writer, blob: OwnedByteView) !void {
    defer freeOwnedBlob(blob);
    const bytes = ownedViewToSlice(blob) orelse return error.OutOfMemory;
    try writer.writeAll(bytes);
}

fn freeOwnedBlob(blob: OwnedByteView) void {
    if (blob.ptr) |ptr| {
        c.free(@ptrCast(@constCast(ptr)));
    }
}

fn ownedViewToSlice(view: OwnedByteView) ?[]const u8 {
    const ptr = view.ptr orelse return null;
    return ptr[0..view.len];
}

fn readU32Le(bytes: []const u8, offset: *usize) ?u32 {
    if (offset.* + 4 > bytes.len) {
        return null;
    }

    const start = offset.*;
    offset.* += 4;
    return @as(u32, bytes[start])
        | (@as(u32, bytes[start + 1]) << 8)
        | (@as(u32, bytes[start + 2]) << 16)
        | (@as(u32, bytes[start + 3]) << 24);
}

fn writeU32LeInto(bytes: []u8, value: u32) void {
    bytes[0] = @intCast(value & 0xff);
    bytes[1] = @intCast((value >> 8) & 0xff);
    bytes[2] = @intCast((value >> 16) & 0xff);
    bytes[3] = @intCast((value >> 24) & 0xff);
}

fn hashCombine(seed: *usize, value: usize) void {
    seed.* ^= value +% hash_combine_magic +% (seed.* << 6) +% (seed.* >> 2);
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
