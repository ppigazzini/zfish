const std = @import("std");
const nnue_parse = @import("nnue_parse.zig");
const nnue_hash = @import("nnue_hash.zig");
const c = @import("libc");
const memory_port = @import("memory");
const graph_layout = @import("graph_layout");
const nnue_accumulator_port = @import("nnue_accumulator");

const output_scale: c_int = 16;
const layer_stacks: usize = 8;
const internal_dir = "<internal>";
const cache_line_size: usize = 64;
const transformed_feature_bytes: usize = 1024;
const square_count: usize = 64;
const no_piece: u8 = 0;
const network_version: u32 = 0x6A448AFA; // upstream nnue_common.h Version (post-merge format)
const hash_combine_magic: usize = 0x9e3779b9;
const none_name = "None";
// EvalFileDefaultName (evaluate.h): the embedded net's default name, a build
// constant. Single source of truth: engine.zig imports this via the
// "network" module rather than re-declaring it (a net bump edits one line).
pub const default_eval_file_name = "nn-af1339a6dea3.nnue";

pub const ByteView = struct {
    ptr: [*]const u8,
    len: usize,
};

pub const OwnedByteView = struct {
    ptr: ?[*]const u8,
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

pub const EvalOutput = struct {
    psqt: c_int,
    positional: c_int,
};

pub const VerifyInfo = struct {
    size_bytes: usize,
    input_dimensions: usize,
    transformed_dimensions: usize,
    fc0_outputs: c_int,
    fc1_outputs: c_int,
};

pub const TraceOutput = struct {
    psqt: [layer_stacks]c_int,
    positional: [layer_stacks]c_int,
    correct_bucket: usize,
};

// The native NNUE parse (parse*Native) populates the Zig-owned inference storage and is
// the sole source of weights. The hooks below are no-op stubs, local to this module.
const embedded_nnue_stub = [_]u8{0};
fn networkEmbeddedBytes() ByteView {
    return .{ .ptr = &embedded_nnue_stub, .len = 1 };
}
fn networkMarkInitialized(network: *anyopaque) void {
    _ = network;
}
fn networkSetLoadedState(
    network: *anyopaque,
    current_name_ptr: [*]const u8,
    current_name_len: usize,
    description_ptr: [*]const u8,
    description_len: usize,
) void {
    _ = network;
    _ = current_name_ptr;
    _ = current_name_len;
    _ = description_ptr;
    _ = description_len;
}
fn networkFeatureTransformerReadBlob(network: *anyopaque, data_ptr: [*]const u8, data_len: usize) usize {
    _ = network;
    _ = data_ptr;
    _ = data_len;
    return 0;
}
fn networkLayerReadBlob(network: *anyopaque, bucket: usize, data_ptr: [*]const u8, data_len: usize) usize {
    _ = network;
    _ = bucket;
    _ = data_ptr;
    _ = data_len;
    return 0;
}

// NNUE network layer forward pass (NetworkArchitecture::propagate), ported to
// Zig. Layers: fc_0 (affine 1024->32) -> {ac_sqr_0, ac_0} -> fc_1 (affine 62->32)
// -> ac_1 -> fc_2 (affine 32->1), plus the fwdOut bias term. Bit-exact with the
// C++ SSSE3 path (integer math). Weights are int8 in the SSSE3-scrambled layout;
// biases int32 linear. WeightScaleBits=6.
// Affine layer over the int8 weights' dpbusd (SSSE3/AVX2/AVX-512-VNNI) tiling.
// The scrambled physical index weightIndexScrambled(j*padded+i,padded,OUT) reduces,
// for padded%4==0, to  phys = (i/4)*OUT*4 + j*4 + (i%4)  -- i.e. for input group
// g=i/4 and sublane m=i%4 the weight of output j lives at g*OUT*4 + j*4 + m, so each
// group's OUT*4 weight bytes are CONTIGUOUS. Load that block, broadcast the group's
// 4 input bytes across it, multiply (input<=127, weight in [-128,127] -> product fits
// i16), then sum each group of 4 sublanes into the i32 accumulator.
//
// Integer sums are order-independent and no partial ever leaves i32's range, so this
// is BIT-EXACT with the prior scalar loop (signature stays 2067208 on every arch);
// it just lets LLVM emit vector multiplies/shuffles (and dpbusd-class ops) instead of
// a scalar MAC. `input.len` must be the padded input dim (a multiple of 4); zero tail
// lanes contribute nothing.
inline fn affineDpbusd(
    comptime OUT: usize,
    out: *[OUT]i32,
    biases: [*]const i32,
    weights: [*]const i8,
    input: []const u8,
) void {
    const N = OUT * 4;
    const Vi16 = @Vector(N, i16);
    const Vo = @Vector(OUT, i32);
    // broadcast mask: lane k takes input sublane k%4 (repeats the 4 input bytes OUT×).
    const rep_mask: @Vector(N, i32) = comptime blk: {
        var m: [N]i32 = undefined;
        for (0..N) |k| m[k] = @intCast(k % 4);
        break :blk m;
    };
    // deinterleave masks: mask[sub] gathers lanes {j*4+sub : j in 0..OUT}.
    const deint: [4]@Vector(OUT, i32) = comptime blk: {
        var d: [4]@Vector(OUT, i32) = undefined;
        for (0..4) |sub| {
            var col: [OUT]i32 = undefined;
            for (0..OUT) |j| col[j] = @intCast(j * 4 + sub);
            d[sub] = col;
        }
        break :blk d;
    };
    var acc: Vo = biases[0..OUT].*;
    const groups = input.len / 4;
    var g: usize = 0;
    while (g < groups) : (g += 1) {
        const in4: @Vector(4, i16) = .{
            @intCast(input[g * 4]),     @intCast(input[g * 4 + 1]),
            @intCast(input[g * 4 + 2]), @intCast(input[g * 4 + 3]),
        };
        const inpat: Vi16 = @shuffle(i16, in4, @as(@Vector(4, i16), undefined), rep_mask);
        const wq: @Vector(N, i8) = weights[g * N ..][0..N].*;
        const w16: Vi16 = wq; // widen i8 -> i16
        const prod: Vi16 = inpat * w16; // exact: |input|<=127, |weight|<=128
        inline for (0..4) |sub| {
            const s: @Vector(OUT, i16) = @shuffle(i16, prod, @as(Vi16, undefined), deint[sub]);
            const s32: Vo = s; // widen i16 -> i32 before summing (4 partials can exceed i16)
            acc += s32;
        }
    }
    out.* = acc;
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
fn layerBiases(bucket: usize, idx: c_int) [*]const i32 {
    return @ptrCast(@alignCast(nativeLayerPtr(bucket, idx, 0) orelse unreachable));
}
fn layerWeights(bucket: usize, idx: c_int) [*]const i8 {
    return @ptrCast(@alignCast(nativeLayerPtr(bucket, idx, 1) orelse unreachable));
}
fn propagateBucket(network: *const anyopaque, bucket: usize, transformed: [*]const u8) c_int {
    // Read the affine-layer weights from the Zig-owned native storage. The native parse
    // writes this storage and is the sole source, so the eval is bench-verified.
    _ = network;
    const fc0_b = layerBiases(bucket, 0);
    const fc0_w = layerWeights(bucket, 0);
    const fc1_b = layerBiases(bucket, 1);
    const fc1_w = layerWeights(bucket, 1);
    const fc2_b = layerBiases(bucket, 2);
    const fc2_w = layerWeights(bucket, 2);

    // fc_0: affine 1024 -> 32 (PaddedInputDimensions = 1024).
    var fc0_out: [32]i32 = undefined;
    affineDpbusd(32, &fc0_out, fc0_b, fc0_w, transformed[0..1024]);

    // ac_sqr_0 / ac_0 on the first FC_0_OUTPUTS=31 outputs, concatenated into 62.
    // upstream 7c7fe322e: ac_sqr_0/ac_0 use WeightScaleBitsLocal = WeightScaleBits+1 = 7.
    var combined: [64]u8 = [_]u8{0} ** 64;
    var i: usize = 0;
    while (i < 31) : (i += 1) {
        const sq: i64 = @as(i64, fc0_out[i]) * @as(i64, fc0_out[i]);
        combined[i] = @intCast(@min(@as(i64, 127), sq >> 21)); // SqrClippedReLU: >> (2*7+7)
        combined[31 + i] = @intCast(@max(@as(i32, 0), @min(@as(i32, 127), fc0_out[i] >> 7))); // ClippedReLU (WSB+1)
    }

    // fc_1: affine 62 -> 32 (PaddedInputDimensions = 64). Pass the full padded 64:
    // combined[62..64] are the zero-init pad, so the extra lanes add nothing.
    var fc1_out: [32]i32 = undefined;
    affineDpbusd(32, &fc1_out, fc1_b, fc1_w, combined[0..64]);

    // ac_1: ClippedReLU 32.
    var ac1: [32]u8 = undefined;
    var k: usize = 0;
    while (k < 32) : (k += 1) ac1[k] = @intCast(@max(@as(i32, 0), @min(@as(i32, 127), fc1_out[k] >> 6)));

    // fc_2: affine 32 -> 1 (PaddedInputDimensions = 32). OUT=1 makes the scramble the
    // identity (phys == i); the dpbusd path handles it uniformly.
    var fc2_out: [1]i32 = undefined;
    affineDpbusd(1, &fc2_out, fc2_b, fc2_w, ac1[0..32]);

    // upstream 7c7fe322e: fwdOut = fc_2_out[0] + fc_0_out[FC_0_OUTPUTS], then scale the sum by
    // 600*OutputScale / (HiddenOneVal*(1<<WeightScaleBits)*2) = 9600/16384, via i64.
    const fwd_sum: i64 = @as(i64, fc2_out[0]) + @as(i64, fc0_out[31]);
    return @intCast(@divTrunc(fwd_sum * (600 * 16), 128 * 64 * 2));
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

    // The verification dims are fixed by the NNUE architecture (sizeof the
    // FeatureTransformer + NetworkArchitecture*LayerStacks; the static InputDimensions /
    // TransformedFeatureDimensions / FC_0_OUTPUTS / FC_1_OUTPUTS). Native constants.
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

// Content hash of the natively-parsed feature transformer (read from the
// Zig-owned storage). Equivalent to FeatureTransformer::get_content_hash.
fn nativeFeatureTransformerContentHash() usize {
    const ft: [*]const u8 = @ptrCast(nativeFtPtr() orelse return 0);
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
        b[ui] = @ptrCast(nativeLayerPtr(bucket, idx, 0) orelse return 0);
        w[ui] = @ptrCast(nativeLayerPtr(bucket, idx, 1) orelse return 0);
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
// only consumers are here in network.zig).
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
    networkMarkInitialized(network);
}

fn setLoadedStateNative(network: *anyopaque, current: []const u8, description: []const u8) void {
    const cl = @min(current.len, nn_current.len);
    @memcpy(nn_current[0..cl], current[0..cl]);
    nn_current_len = cl;
    const dl = @min(description.len, nn_description.len);
    @memcpy(nn_description[0..dl], description[0..dl]);
    nn_description_len = dl;
    networkSetLoadedState(network, current.ptr, current.len, description.ptr, description.len);
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
        .psqt = networkTransformBucket(
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
    const board = graph_layout.positionBoard(pos); // Position.board [64]u8 (offset 0)
    var count: usize = 0;
    var sq: usize = 0;
    while (sq < square_count) : (sq += 1) {
        if (board[sq] != no_piece) count += 1;
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
    _ = loadNetworkBytes(network, viewToSlice(networkEmbeddedBytes()), default_name);
}

// Gather one layer stack's native biases/weights slices (fc_0/fc_1/fc_2).
fn nativeLayerArrays(network: *const anyopaque, bucket: usize) ?struct { b: [3][]const u8, w: [3][]const u8 } {
    _ = network;
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


// Native-owned inference storage. The native parse writes the weights straight
// here; inference reads from the same memory. Owned by this module (M16.7): the
// feature transformer is ~106 MB of SIMD-permuted weights, and each per-bucket
// affine layer stack has fc_0/fc_1/fc_2 biases+weights.
var native_ft_ptr_storage: ?*anyopaque = null;
var native_ft_len: usize = 0;

fn nativeFtStorage(n: usize) ?[*]u8 {
    if (n == 0) return null;
    if (native_ft_ptr_storage != null and native_ft_len != n) {
        memory_port.alignedLargePagesFree(native_ft_ptr_storage);
        native_ft_ptr_storage = null;
    }
    if (native_ft_ptr_storage == null) {
        native_ft_ptr_storage = memory_port.alignedLargePagesAlloc(n) orelse return null;
        native_ft_len = n;
    }
    return @ptrCast(native_ft_ptr_storage.?);
}

pub fn nativeFtPtr() ?*const anyopaque {
    return native_ft_ptr_storage;
}

const layer_stacks_n = 8;
const layers_per_stack = 3;

var native_layer_w: [layer_stacks_n][layers_per_stack]?*anyopaque =
    .{.{ null, null, null }} ** layer_stacks_n;
var native_layer_b: [layer_stacks_n][layers_per_stack]?*anyopaque =
    .{.{ null, null, null }} ** layer_stacks_n;

fn nativeLayerStorage(bucket: usize, idx: c_int, is_weights: c_int, n: usize) ?[*]u8 {
    if (bucket >= layer_stacks_n or idx < 0 or idx >= layers_per_stack or n == 0) return null;
    const ui: usize = @intCast(idx);
    const slot = if (is_weights != 0) &native_layer_w[bucket][ui] else &native_layer_b[bucket][ui];
    if (slot.* == null) slot.* = memory_port.alignedLargePagesAlloc(n) orelse return null;
    return @ptrCast(slot.*.?);
}

fn nativeLayerPtr(bucket: usize, idx: c_int, is_weights: c_int) ?*const anyopaque {
    if (bucket >= layer_stacks_n or idx < 0 or idx >= layers_per_stack) return null;
    const ui: usize = @intCast(idx);
    return if (is_weights != 0) native_layer_w[bucket][ui] else native_layer_b[bucket][ui];
}

// FT transform for one output bucket. Reads weights from the native feature-transformer
// storage above (always resident after a network load) and runs the Zig accumulator
// transform. Relocated from main.zig (M16.7).
fn networkTransformBucket(
    network: *const anyopaque,
    pos: *const anyopaque,
    accumulator_stack: *anyopaque,
    cache: *anyopaque,
    bucket: usize,
    transformed_ptr: [*]u8,
) c_int {
    _ = network;
    const ft = native_ft_ptr_storage orelse @panic("native feature-transformer storage not initialized");
    const stm = graph_layout.positionSideToMove(pos);
    return nnue_accumulator_port.transformBucket(accumulator_stack, pos, ft, cache, bucket, stm, transformed_ptr);
}

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

fn readFeatureTransformer(network: *anyopaque, bytes: []const u8, offset: *usize) bool {
    const remaining = bytes[offset.*..];
    const consumed = parseFeatureTransformerNative(remaining);
    if (consumed == 0 or consumed > remaining.len) {
        return false;
    }
    // No-op stub (the native parse is the sole source); return ignored.
    _ = networkFeatureTransformerReadBlob(network, remaining.ptr, remaining.len);
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

fn readLayer(network: *anyopaque, bucket: usize, bytes: []const u8, offset: *usize) bool {
    const remaining = bytes[offset.*..];
    const consumed = parseLayerNative(bucket, remaining);
    if (consumed == 0 or consumed > remaining.len) {
        return false;
    }
    // No-op stub (the native parse is the sole source); return ignored.
    _ = networkLayerReadBlob(network, bucket, remaining.ptr, remaining.len);
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
