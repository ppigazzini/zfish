const std = @import("std");
const nnue_parse = @import("nnue_parse.zig");
const nnue_hash = @import("nnue_hash.zig");
const weight_storage = @import("nnue_weight_storage.zig");
const nnue_inference = @import("nnue_inference.zig");
const memory_port = @import("memory");
const position_types = @import("position_types");
const nnue_accumulator_port = @import("nnue_accumulator");

const Position = position_types.Position;

const layer_stacks: usize = 8;
const internal_dir = "<internal>";
const network_version: u32 = 0x6A448AFA; // upstream nnue_common.h Version (post-merge format)
const none_name = "None";
// EvalFileDefaultName (evaluate.h): the embedded net's default name, a build
// constant. Single source of truth: engine.zig imports this via the
// "network" module rather than re-declaring it (a net bump edits one line).
pub const default_eval_file_name = "nn-af1339a6dea3.nnue";

/// Opaque handle to the network subsystem (M18.5). The NNUE weights live in this
/// module's globals (native_ft_ptr_storage &c.), so there is no struct to point at --
/// the engine holds a malloc(1) placeholder. An `opaque {}` gives the SharedState
/// bundle a distinct `*Network` handle (not a bare *anyopaque) without inventing a
/// fake layout; it is the same idiom the B4 arena handles use.
pub const Network = opaque {};

// Inference (forward pass) lives in the nnue_inference leaf now; re-export the
// public entry points + result types so the network module's port surface --
// which the engine, worker, and trace callers resolve through -- is unchanged.
pub const evaluate = nnue_inference.evaluate;
pub const traceEvaluate = nnue_inference.traceEvaluate;
pub const EvalOutput = nnue_inference.EvalOutput;
pub const TraceOutput = nnue_inference.TraceOutput;

pub const ByteView = struct {
    ptr: [*]const u8,
    len: usize,
};

pub const SaveResult = struct {
    saved: u8,
    message: ?[*:0]u8,
};

pub const VerifyResult = struct {
    should_exit: u8,
    message: ?[*:0]u8,
};

pub const VerifyInfo = struct {
    size_bytes: usize,
    input_dimensions: usize,
    transformed_dimensions: usize,
    fc0_outputs: c_int,
    fc1_outputs: c_int,
};

// The native NNUE parse (parse*Native) populates the Zig-owned inference storage and is
// the sole source of weights. The hooks below are no-op stubs, local to this module.
const embedded_nnue_stub = [_]u8{0};
fn networkEmbeddedBytes() ByteView {
    return .{ .ptr = &embedded_nnue_stub, .len = 1 };
}

// Native affine-layer byte sizes — fixed by the NNUE architecture
// (fc_0 1024->32, fc_1 64->32, fc_2 32->1; biases int32 linear, weights int8 SSSE3-scrambled).
// sizeof(AffineTransform.biases/weights): {128,128,4} / {32768,2048,32}.
const layer_biases_bytes = [3]usize{ 128, 128, 4 };
const layer_weights_bytes = [3]usize{ 32768, 2048, 32 };
fn layerBiasesBytes(idx: c_int) usize {
    return layer_biases_bytes[@intCast(idx)];
}
fn layerWeightsBytes(idx: c_int) usize {
    return layer_weights_bytes[@intCast(idx)];
}

pub fn load(
    root_directory_ptr: [*]const u8,
    root_directory_len: usize,
    evalfile_path_ptr: [*]const u8,
    evalfile_path_len: usize,
) void {
    const root_directory = root_directory_ptr[0..root_directory_len];
    const default_name = default_eval_file_name;
    const evalfile_path = if (evalfile_path_len == 0)
        default_name
    else
        evalfile_path_ptr[0..evalfile_path_len];
    const dirs = [_][]const u8{ internal_dir, "", root_directory };

    for (dirs) |directory| {
        if (!equalCurrentName(evalfile_path)) {
            if (!std.mem.eql(u8, directory, internal_dir)) {
                loadUserNet(directory, evalfile_path);
            }

            if (std.mem.eql(u8, directory, internal_dir) and std.mem.eql(u8, evalfile_path, default_name)) {
                loadInternal();
            }
        }
    }
}

pub fn save(
    has_filename: u8,
    filename_ptr: [*]const u8,
    filename_len: usize,
) SaveResult {
    const default_name = default_eval_file_name;
    const current_name = nnCurrent();

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

    const saved = saveNamed(actual_filename);
    return .{
        .saved = boolToU8(saved),
        .message = if (saved)
            allocMessage("Network saved successfully to {s}", .{actual_filename})
        else
            allocMessage("Failed to export a net", .{}),
    };
}

pub fn verify(
    evalfile_path_ptr: [*]const u8,
    evalfile_path_len: usize,
) VerifyResult {
    const default_name = default_eval_file_name;
    const current_name = nnCurrent();
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

    // The verification dims are fixed by the NNUE architecture (sizeof the
    // FeatureTransformer + NetworkArchitecture*LayerStacks; the static InputDimensions /
    // TransformedFeatureDimensions / FC_0_OUTPUTS / FC_1_OUTPUTS). Native constants.
    const info = VerifyInfo{
        .size_bytes = 111263232,
        .input_dimensions = 83248,
        .transformed_dimensions = 1024,
        .fc0_outputs = 31,
        .fc1_outputs = 32,
    };
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

// Content hash of the natively-parsed feature transformer (read from the
// Zig-owned storage). Equivalent to FeatureTransformer::get_content_hash.

// Content hash of one natively-parsed layer stack. Equivalent to
// NetworkArchitecture::get_content_hash.

// Zig-owned EvalFile dynamic state + the native weight storage live in the
// nnue_weight_storage leaf now (shared owner for the inference and I/O paths);
// alias the accessors back so the call sites here stay unqualified.
const nnCurrent = weight_storage.nnCurrent;
const nnDescription = weight_storage.nnDescription;
const markInitializedNative = weight_storage.markInitializedNative;
const setLoadedStateNative = weight_storage.setLoadedStateNative;
const equalCurrentName = weight_storage.equalCurrentName;
const nativeFtStorage = weight_storage.nativeFtStorage;
const nativeLayerStorage = weight_storage.nativeLayerStorage;
const nativeLayerPtr = weight_storage.nativeLayerPtr;
pub const nativeFtPtr = weight_storage.nativeFtPtr;

// Content hash of the eval-file names (std::hash<EvalFile>), computed natively
// from the Zig-owned EvalFile state.

const Header = struct {
    hash_value: u32,
    description: []const u8,
};

fn loadUserNet(dir: []const u8, evalfile_path: []const u8) void {
    markInitializedNative();

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
    _ = loadNetworkBytes(bytes, evalfile_path);
}

fn loadInternal() void {
    markInitializedNative();

    const default_name = default_eval_file_name;
    _ = loadNetworkBytes(viewToSlice(networkEmbeddedBytes()), default_name);
}

// Gather one layer stack's native biases/weights slices (fc_0/fc_1/fc_2).
fn nativeLayerArrays(bucket: usize) ?struct { b: [3][]const u8, w: [3][]const u8 } {
    var b: [3][]const u8 = undefined;
    var w: [3][]const u8 = undefined;
    var idx: c_int = 0;
    while (idx < 3) : (idx += 1) {
        const ui: usize = @intCast(idx);
        const bp: [*]const u8 = @ptrCast(nativeLayerPtr(bucket, idx, 0) orelse return null);
        const wp: [*]const u8 = @ptrCast(nativeLayerPtr(bucket, idx, 1) orelse return null);
        b[ui] = bp[0..layerBiasesBytes(idx)];
        w[ui] = wp[0..layerWeightsBytes(idx)];
    }
    return .{ .b = b, .w = w };
}

// Serialize the native feature transformer into `out` (write_parameters blob,
// including the leading component hash).
fn serializeFtNative(out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    const ft: [*]const u8 = @ptrCast(nativeFtPtr() orelse return error.NoNetwork);
    try nnue_parse.serializeFeatureTransformer(
        ft[0..nnue_parse.ft_total_bytes],
        nnue_hash.featureTransformerHashValue(),
        out,
        a,
    );
}

// Serialize one native layer stack into `out`.
fn serializeLayerNative(bucket: usize, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    const arr = nativeLayerArrays(bucket) orelse return error.NoNetwork;
    try nnue_parse.serializeLayer(nnue_hash.architectureHashValue(), arr.b, arr.w, out, a);
}

fn saveNamed(filename: []const u8) bool {
    const current_name = nnCurrent();
    if (current_name.len == 0 or std.mem.eql(u8, current_name, none_name)) {
        return false;
    }

    const description = nnDescription();
    var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    const io = threaded.io();
    const file = openFileForWrite(io, filename) catch return false;
    defer file.close(io);
    var writer_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &writer_buffer);

    const a = std.heap.c_allocator;
    var blob = std.ArrayList(u8).empty;
    defer blob.deinit(a);

    writeHeader(&writer.interface, nnue_hash.networkHashValue(), description) catch return false;

    serializeFtNative(&blob, a) catch return false;
    writer.interface.writeAll(blob.items) catch return false;

    var bucket: usize = 0;
    while (bucket < layer_stacks) : (bucket += 1) {
        blob.clearRetainingCapacity();
        serializeLayerNative(bucket, &blob, a) catch return false;
        writer.interface.writeAll(blob.items) catch return false;
    }

    writer.interface.flush() catch return false;

    return true;
}

fn loadNetworkBytes(bytes: []const u8, current_name: []const u8) bool {
    var offset: usize = 0;
    const header = readHeader(bytes, &offset) orelse return false;
    if (header.hash_value != nnue_hash.networkHashValue()) {
        return false;
    }

    if (!readFeatureTransformer(bytes, &offset)) {
        return false;
    }

    var bucket: usize = 0;
    while (bucket < layer_stacks) : (bucket += 1) {
        if (!readLayer(bucket, bytes, &offset)) {
            return false;
        }
    }

    if (offset != bytes.len) {
        return false;
    }

    setLoadedStateNative(current_name, header.description);
    // The native parse is the sole source of weights; correctness is verified end-to-end
    // by the eval gates (bench / search-parity), and the offset==bytes.len check above
    // verifies the consumed-byte count.
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

// FT transform for one output bucket. Reads weights from the native feature-transformer
// storage above (always resident after a network load) and runs the Zig accumulator
// transform. Relocated from main.zig (M16.7).

// Parse the feature transformer natively into the Zig-owned storage and return the bytes
// consumed (leading component hash + the LEB-coded params). The native parse is the sole
// source (the eval gates verify the weights end-to-end, and the offset==bytes.len check
// at the end of loadNetworkBytes verifies the consumed count).
fn parseFeatureTransformerNative(blob: []const u8) usize {
    const dst_ptr = nativeFtStorage(nnue_parse.ft_total_bytes) orelse
        @panic("native feature-transformer storage allocation failed");
    const dst = dst_ptr[0..nnue_parse.ft_total_bytes];
    return nnue_parse.parseFeatureTransformer(blob, dst) orelse
        @panic("native feature-transformer parse failed");
}

fn readFeatureTransformer(bytes: []const u8, offset: *usize) bool {
    const remaining = bytes[offset.*..];
    const consumed = parseFeatureTransformerNative(remaining);
    if (consumed == 0 or consumed > remaining.len) {
        return false;
    }
    offset.* += consumed;
    return true;
}

// Parse this bucket's affine layers natively into the Zig-owned storage (skip the leading
// architecture hash, then fc_0/fc_1/fc_2 biases+scrambled weights) and return the bytes
// consumed. Native is the sole source.
fn parseLayerNative(bucket: usize, blob: []const u8) usize {
    var pos: usize = 4; // architecture component hash
    var idx: c_int = 0;
    while (idx < 3) : (idx += 1) {
        const wb = layerWeightsBytes(idx);
        const bb = layerBiasesBytes(idx);
        const bdst = nativeLayerStorage(bucket, idx, 0, bb) orelse
            @panic("native affine-layer storage allocation failed");
        const wdst = nativeLayerStorage(bucket, idx, 1, wb) orelse
            @panic("native affine-layer storage allocation failed");
        const used = nnue_parse.parseLayer(blob[pos..], bdst[0..bb], wdst[0..wb]) orelse
            @panic("native affine-layer parse failed");
        pos += used;
    }
    return pos;
}

fn readLayer(bucket: usize, bytes: []const u8, offset: *usize) bool {
    const remaining = bytes[offset.*..];
    const consumed = parseLayerNative(bucket, remaining);
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

fn readU32Le(bytes: []const u8, offset: *usize) ?u32 {
    if (offset.* + 4 > bytes.len) {
        return null;
    }

    const start = offset.*;
    offset.* += 4;
    return @as(u32, bytes[start]) | (@as(u32, bytes[start + 1]) << 8) | (@as(u32, bytes[start + 2]) << 16) | (@as(u32, bytes[start + 3]) << 24);
}

fn writeU32LeInto(bytes: []u8, value: u32) void {
    bytes[0] = @intCast(value & 0xff);
    bytes[1] = @intCast((value >> 8) & 0xff);
    bytes[2] = @intCast((value >> 16) & 0xff);
    bytes[3] = @intCast((value >> 24) & 0xff);
}

fn viewToSlice(view: ByteView) []const u8 {
    return view.ptr[0..view.len];
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

test {
    @import("std").testing.refAllDecls(@This());
}
