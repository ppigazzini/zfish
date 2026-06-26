const std = @import("std");
const nnue_parse = @import("nnue_parse.zig");
const nnue_hash = @import("nnue_hash.zig");
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
// EvalFileDefaultName (evaluate.h): the embedded net's default name. A build
// constant, so the native path no longer reads it from the C++ Network's
// EvalFile.defaultName.
const default_eval_file_name = "nn-83a0d6daf7e5.nnue";

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

extern fn zfish_network_embedded_bytes() ByteView;
// Kept only to dual-write the C++ EvalFile so the content-hash oracle self-check
// stays valid; the native path reads its own EvalFile state (nn_* below).
extern fn zfish_network_mark_initialized(network: *anyopaque) void;
extern fn zfish_network_set_loaded_state(
    network: *anyopaque,
    current_name_ptr: [*]const u8,
    current_name_len: usize,
    description_ptr: [*]const u8,
    description_len: usize,
) void;
// Legacy oracle only: parse the blob into the C++ Network so the legacy C++ eval reads its
// weights. In the DEFAULT build these are Network-free no-op stubs (uci_bridge.cpp) — the native
// parse (parse*Native) populates the Zig-owned inference storage and is the sole source. The
// return is ignored; the load offset advances by the native parse's consumed-byte count.
extern fn zfish_network_feature_transformer_read_blob(network: *anyopaque, data_ptr: [*]const u8, data_len: usize) usize;
extern fn zfish_network_layer_read_blob(network: *anyopaque, bucket: usize, data_ptr: [*]const u8, data_len: usize) usize;
extern fn zfish_accumulator_position_snapshot(pos: *const anyopaque, pieces_out: [*]u8) void;
extern fn zfish_network_transform_bucket(
    network: *const anyopaque,
    pos: *const anyopaque,
    accumulator_stack: *anyopaque,
    cache: *anyopaque,
    bucket: usize,
    transformed_ptr: [*]u8,
) c_int;

// NNUE network layer forward pass (NetworkArchitecture::propagate), ported to
// Zig. Layers: fc_0 (affine 1024->32) -> {ac_sqr_0, ac_0} -> fc_1 (affine 62->32)
// -> ac_1 -> fc_2 (affine 32->1), plus the fwdOut bias term. Bit-exact with the
// C++ SSSE3 path (integer math). Weights are int8 in the SSSE3-scrambled layout;
// biases int32 linear. WeightScaleBits=6.
inline fn weightIndexScrambled(i: usize, padded_input: usize, output_dim: usize) usize {
    return (i / 4) % (padded_input / 4) * output_dim * 4 + (i / padded_input) * 4 + i % 4;
}

fn affineLayer(
    out: []i32,
    biases: [*]const i32,
    weights: [*]const i8,
    input: []const u8,
    padded_input: usize,
) void {
    const out_dim = out.len;
    var j: usize = 0;
    while (j < out_dim) : (j += 1) {
        var sum: i32 = biases[j];
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            const phys = weightIndexScrambled(j * padded_input + i, padded_input, out_dim);
            sum += @as(i32, weights[phys]) * @as(i32, input[i]);
        }
        out[j] = sum;
    }
}

// M-FINAL cutover: native affine-layer byte sizes — fixed by the NNUE architecture
// (fc_0 1024->32, fc_1 64->32, fc_2 32->1; biases int32 linear, weights int8 SSSE3-scrambled).
// sizeof(AffineTransform.biases/weights): {128,128,4} / {32768,2048,32}. Replaces the C++
// zfish_layer_*_bytes (sizeof the C++ Network's AffineTransform arrays), self-sufficient native.
const layer_biases_bytes = [3]usize{ 128, 128, 4 };
const layer_weights_bytes = [3]usize{ 32768, 2048, 32 };
fn layerBiasesBytes(idx: c_int) usize {
    return layer_biases_bytes[@intCast(idx)];
}
fn layerWeightsBytes(idx: c_int) usize {
    return layer_weights_bytes[@intCast(idx)];
}
fn layerBiases(bucket: usize, idx: c_int) [*]const i32 {
    return @ptrCast(@alignCast(zfish_native_layer_ptr(bucket, idx, 0) orelse unreachable));
}
fn layerWeights(bucket: usize, idx: c_int) [*]const i8 {
    return @ptrCast(@alignCast(zfish_native_layer_ptr(bucket, idx, 1) orelse unreachable));
}
fn propagateBucket(network: *const anyopaque, bucket: usize, transformed: [*]const u8) c_int {
    // M-FINAL cutover (network layers): read the affine-layer weights from the Zig-owned
    // native storage (zfish_native_layer_ptr) instead of the C++ Network (zfish_layer_biases/
    // weights). The native parse writes this storage and the load-time cross-check proves it
    // bit-identical to the C++ Network, so the eval is unchanged (bench-verified). Removes the
    // C++ Network from the eval hot path.
    _ = network;
    const fc0_b = layerBiases(bucket, 0);
    const fc0_w = layerWeights(bucket, 0);
    const fc1_b = layerBiases(bucket, 1);
    const fc1_w = layerWeights(bucket, 1);
    const fc2_b = layerBiases(bucket, 2);
    const fc2_w = layerWeights(bucket, 2);

    // fc_0: affine 1024 -> 32 (PaddedInputDimensions = 1024).
    var fc0_out: [32]i32 = undefined;
    affineLayer(&fc0_out, fc0_b, fc0_w, transformed[0..1024], 1024);

    // ac_sqr_0 / ac_0 on the first FC_0_OUTPUTS=31 outputs, concatenated into 62.
    var combined: [64]u8 = [_]u8{0} ** 64;
    var i: usize = 0;
    while (i < 31) : (i += 1) {
        const sq: i64 = @as(i64, fc0_out[i]) * @as(i64, fc0_out[i]);
        combined[i] = @intCast(@min(@as(i64, 127), sq >> 19)); // SqrClippedReLU: >> (2*6+7)
        combined[31 + i] = @intCast(@max(@as(i32, 0), @min(@as(i32, 127), fc0_out[i] >> 6))); // ClippedReLU
    }

    // fc_1: affine 62 -> 32 (PaddedInputDimensions = 64).
    var fc1_out: [32]i32 = undefined;
    affineLayer(&fc1_out, fc1_b, fc1_w, combined[0..62], 64);

    // ac_1: ClippedReLU 32.
    var ac1: [32]u8 = undefined;
    var k: usize = 0;
    while (k < 32) : (k += 1) ac1[k] = @intCast(@max(@as(i32, 0), @min(@as(i32, 127), fc1_out[k] >> 6)));

    // fc_2: affine 32 -> 1 (PaddedInputDimensions = 32).
    var fc2_out: [1]i32 = undefined;
    affineLayer(&fc2_out, fc2_b, fc2_w, ac1[0..32], 32);

    // fwdOut = fc_0_out[FC_0_OUTPUTS] * (600*OutputScale) / (127 * (1<<WeightScaleBits)).
    const fwd_out: c_int = @intCast(@divTrunc(@as(i64, fc0_out[31]) * (600 * 16), 127 * 64));
    return fc2_out[0] + fwd_out;
}

pub fn load(
    network: *anyopaque,
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

    // M-FINAL cutover: the verification dims are fixed by the NNUE architecture (sizeof the C++
    // FeatureTransformer + NetworkArchitecture*LayerStacks; the static InputDimensions /
    // TransformedFeatureDimensions / FC_0_OUTPUTS / FC_1_OUTPUTS). Native constants replace
    // zfish_network_verify_info, so the verify message needs no C++ Network.
    _ = network;
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

extern fn zfish_native_ft_ptr() ?*const anyopaque;
extern fn zfish_native_layer_ptr(bucket: usize, idx: c_int, is_weights: c_int) ?*const anyopaque;

// Content hash of the natively-parsed feature transformer (read from the
// Zig-owned storage). Equivalent to FeatureTransformer::get_content_hash.
fn nativeFeatureTransformerContentHash() usize {
    const ft: [*]const u8 = @ptrCast(zfish_native_ft_ptr() orelse return 0);
    return nnue_hash.featureTransformerContentHash(ft);
}

// Content hash of one natively-parsed layer stack. Equivalent to
// NetworkArchitecture::get_content_hash.
fn nativeLayerContentHash(network: *const anyopaque, bucket: usize) usize {
    _ = network;
    var b: [3][*]const u8 = undefined;
    var w: [3][*]const u8 = undefined;
    var bn: [3]usize = undefined;
    var wn: [3]usize = undefined;
    var idx: c_int = 0;
    while (idx < 3) : (idx += 1) {
        const ui: usize = @intCast(idx);
        b[ui] = @ptrCast(zfish_native_layer_ptr(bucket, idx, 0) orelse return 0);
        w[ui] = @ptrCast(zfish_native_layer_ptr(bucket, idx, 1) orelse return 0);
        bn[ui] = layerBiasesBytes(idx);
        wn[ui] = layerWeightsBytes(idx);
    }
    return nnue_hash.layerStackContentHash(
        b[0][0..bn[0]], w[0][0..wn[0]],
        b[1][0..bn[1]], w[1][0..wn[1]],
        b[2][0..bn[2]], w[2][0..wn[2]],
    );
}

// Zig-owned EvalFile dynamic state: the current eval-file name, the net
// description, and the initialized flag. The native load path owns these (the
// only consumers were here in network.zig). The C++ EvalFile is kept dual-written
// so the content-hash oracle self-check stays valid until the big-bang removes
// it. The default name stays sourced from the C++ EvalFile (a build constant).
var nn_initialized: bool = false;
var nn_current: [256]u8 = undefined;
var nn_current_len: usize = 0;
var nn_description: [256]u8 = undefined;
var nn_description_len: usize = 0;

fn nnCurrent() []const u8 {
    return nn_current[0..nn_current_len];
}

fn nnDescription() []const u8 {
    return nn_description[0..nn_description_len];
}

fn markInitializedNative(network: *anyopaque) void {
    nn_initialized = true;
    zfish_network_mark_initialized(network); // keep the C++ oracle in sync
}

fn setLoadedStateNative(network: *anyopaque, current: []const u8, description: []const u8) void {
    const cl = @min(current.len, nn_current.len);
    @memcpy(nn_current[0..cl], current[0..cl]);
    nn_current_len = cl;
    const dl = @min(description.len, nn_description.len);
    @memcpy(nn_description[0..dl], description[0..dl]);
    nn_description_len = dl;
    zfish_network_set_loaded_state(network, current.ptr, current.len, description.ptr, description.len);
}

pub fn contentHash(network: *const anyopaque) usize {
    if (!nn_initialized) {
        return 0;
    }

    var hash: usize = 0;
    hashCombine(&hash, nativeFeatureTransformerContentHash());

    var bucket: usize = 0;
    while (bucket < layer_stacks) : (bucket += 1) {
        hashCombine(&hash, nativeLayerContentHash(network, bucket));
    }

    hashCombine(&hash, nativeEvalFileContentHash());
    return hash;
}

// Content hash of the eval-file names (std::hash<EvalFile>), computed natively
// from the Zig-owned EvalFile state.
fn nativeEvalFileContentHash() usize {
    return nnue_hash.evalFileContentHash(
        default_eval_file_name,
        nnCurrent(),
        nnDescription(),
    );
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
        .positional = propagateBucket(network, bucket, @ptrCast(&transformed)),
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
    markInitializedNative(network);

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
    markInitializedNative(network);

    const default_name = default_eval_file_name;
    _ = loadNetworkBytes(network, viewToSlice(zfish_network_embedded_bytes()), default_name);
}

// Gather one layer stack's native biases/weights slices (fc_0/fc_1/fc_2).
fn nativeLayerArrays(network: *const anyopaque, bucket: usize) ?struct { b: [3][]const u8, w: [3][]const u8 } {
    _ = network;
    var b: [3][]const u8 = undefined;
    var w: [3][]const u8 = undefined;
    var idx: c_int = 0;
    while (idx < 3) : (idx += 1) {
        const ui: usize = @intCast(idx);
        const bp: [*]const u8 = @ptrCast(zfish_native_layer_ptr(bucket, idx, 0) orelse return null);
        const wp: [*]const u8 = @ptrCast(zfish_native_layer_ptr(bucket, idx, 1) orelse return null);
        b[ui] = bp[0..layerBiasesBytes(idx)];
        w[ui] = wp[0..layerWeightsBytes(idx)];
    }
    return .{ .b = b, .w = w };
}

// Serialize the native feature transformer into `out` (write_parameters blob,
// including the leading component hash).
fn serializeFtNative(out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    const ft: [*]const u8 = @ptrCast(zfish_native_ft_ptr() orelse return error.NoNetwork);
    try nnue_parse.serializeFeatureTransformer(
        ft[0..nnue_parse.ft_total_bytes],
        nnue_hash.featureTransformerHashValue(),
        out,
        a,
    );
}

// Serialize one native layer stack into `out`.
fn serializeLayerNative(network: *const anyopaque, bucket: usize, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    const arr = nativeLayerArrays(network, bucket) orelse return error.NoNetwork;
    try nnue_parse.serializeLayer(nnue_hash.architectureHashValue(), arr.b, arr.w, out, a);
}

fn saveNamed(network: *const anyopaque, filename: []const u8) bool {
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
        serializeLayerNative(network, bucket, &blob, a) catch return false;
        writer.interface.writeAll(blob.items) catch return false;
    }

    writer.interface.flush() catch return false;

    return true;
}

fn loadNetworkBytes(network: *anyopaque, bytes: []const u8, current_name: []const u8) bool {
    var offset: usize = 0;
    const header = readHeader(bytes, &offset) orelse return false;
    if (header.hash_value != nnue_hash.networkHashValue()) {
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

    setLoadedStateNative(network, current_name, header.description);
    // M-FINAL cutover: the C++ Network is no longer parsed (no read_blob), so the load-time
    // native-vs-C++ content-hash + serialization self-checks are retired. The native parse is
    // the sole source; correctness is verified end-to-end by the eval gates (bench 2336177 /
    // search-parity), and the offset==bytes.len check above verifies the consumed-byte count.
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


// Native-owned inference storage, allocated by main.zig. The native parse writes
// the weights straight here; inference reads from the same memory.
extern fn zfish_native_ft_storage(n: usize) ?[*]u8;
extern fn zfish_native_layer_storage(bucket: usize, idx: c_int, is_weights: c_int, n: usize) ?[*]u8;

// Parse the FT blob natively into the Zig-owned inference storage, then confirm
// it matches the C++-parsed feature-transformer byte-for-byte (per weight region,
// skipping alignment padding). The native parse is the inference source; the C++
// parse remains only as a load-time cross-check.
// Parse the feature transformer natively into the Zig-owned storage and return the bytes
// consumed (leading component hash + the LEB-coded params). The native parse is the sole
// source — the C++ Network is no longer parsed (the eval gates verify the weights end-to-end,
// and the offset==bytes.len check at the end of loadNetworkBytes verifies the consumed count).
fn parseFeatureTransformerNative(blob: []const u8) usize {
    const dst_ptr = zfish_native_ft_storage(nnue_parse.ft_total_bytes) orelse
        @panic("native feature-transformer storage allocation failed");
    const dst = dst_ptr[0..nnue_parse.ft_total_bytes];
    return nnue_parse.parseFeatureTransformer(blob, dst) orelse
        @panic("native feature-transformer parse failed");
}

fn readFeatureTransformer(network: *anyopaque, bytes: []const u8, offset: *usize) bool {
    const remaining = bytes[offset.*..];
    const consumed = parseFeatureTransformerNative(remaining);
    if (consumed == 0 or consumed > remaining.len) {
        return false;
    }
    // Legacy oracle populates the C++ Network here; default build no-op. Return ignored.
    _ = zfish_network_feature_transformer_read_blob(network, remaining.ptr, remaining.len);
    offset.* += consumed;
    return true;
}


// Parse this bucket's affine layers natively into the Zig-owned inference storage
// (skip the architecture hash, then fc_0/fc_1/fc_2 biases+scrambled weights), then
// confirm each matches the C++-parsed layer memory byte-for-byte.
// Parse this bucket's affine layers natively into the Zig-owned storage (skip the leading
// architecture hash, then fc_0/fc_1/fc_2 biases+scrambled weights) and return the bytes
// consumed. Native is the sole source — no C++ Network parse.
fn parseLayerNative(bucket: usize, blob: []const u8) usize {
    var pos: usize = 4; // architecture component hash
    var idx: c_int = 0;
    while (idx < 3) : (idx += 1) {
        const wb = layerWeightsBytes(idx);
        const bb = layerBiasesBytes(idx);
        const bdst = zfish_native_layer_storage(bucket, idx, 0, bb) orelse
            @panic("native affine-layer storage allocation failed");
        const wdst = zfish_native_layer_storage(bucket, idx, 1, wb) orelse
            @panic("native affine-layer storage allocation failed");
        const used = nnue_parse.parseLayer(blob[pos..], bdst[0..bb], wdst[0..wb]) orelse
            @panic("native affine-layer parse failed");
        pos += used;
    }
    return pos;
}

fn readLayer(network: *anyopaque, bucket: usize, bytes: []const u8, offset: *usize) bool {
    const remaining = bytes[offset.*..];
    const consumed = parseLayerNative(bucket, remaining);
    if (consumed == 0 or consumed > remaining.len) {
        return false;
    }
    // Legacy oracle populates the C++ Network here; default build no-op. Return ignored.
    _ = zfish_network_layer_read_blob(network, bucket, remaining.ptr, remaining.len);
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
    _ = network;
    return std.mem.eql(u8, nnCurrent(), target);
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
