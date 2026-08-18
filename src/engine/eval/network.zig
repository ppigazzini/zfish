const std = @import("std");
const builtin = @import("builtin");
const nnue_parse = @import("nnue_parse.zig");
const nnue_dims = @import("nnue_dimensions");
const nnue_hash = @import("nnue_hash.zig");
const weight_storage = @import("nnue_weight_storage.zig");
const nnue_inference = @import("nnue_inference.zig");
const position_types = @import("position_types");
const nnue_accumulator_port = @import("nnue_accumulator");
const network_parse = @import("network_parse.zig");

// Take the .nnue READER from network_parse.zig, split off on the 500-line lint. The seam is
// the file's own: everything that walks an untrusted file into the live weights lives there,
// and what remains here is the option-facing face -- load / save / verify. The dependency runs
// one way, network -> network_parse, so the pair is not a file cycle.
const loadNetworkBytes = network_parse.loadNetworkBytes;
const writeU32LeInto = network_parse.writeU32LeInto;
const network_version = network_parse.network_version;

const Position = position_types.Position;

const layer_stacks: usize = 8;
const internal_dir = "<internal>";
const none_name = "None";
// Name the embedded net's default (EvalFileDefaultName, evaluate.h), a build
// constant. Keep a single source of truth: engine.zig imports this via the
// "network" module rather than re-declaring it (a net bump edits one line).
pub const default_eval_file_name = "nn-ab28990d4ea3.nnue";

/// Expose an opaque handle to the network subsystem. The NNUE weights live in this
/// module's globals (ft_ptr_storage &c.), so there is no struct to point at --
/// the engine holds a malloc(1) placeholder. An `opaque {}` gives the SharedState
/// bundle a distinct `*Network` handle (not a bare *anyopaque) without inventing a
/// fake layout; it is the same idiom the B4 arena handles use.
pub const Network = opaque {};

// Re-export the inference (forward pass) public entry points + result types from
// the nnue_inference leaf so the engine, worker, and trace callers resolve them
// through the network module.
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
    message: ?[]u8,
};

pub const VerifyResult = struct {
    should_exit: u8,
    message: ?[]u8,
};

pub const VerifyInfo = struct {
    size_bytes: usize,
    input_dimensions: usize,
    transformed_dimensions: usize,
    fc0_outputs: i32,
    fc1_outputs: i32,
};

// Populate the Zig-owned inference storage from the NNUE parse, the sole source
// of weights. The hooks below are no-op stubs, local to this module.
const embedded_nnue_stub = [_]u8{0};
fn networkEmbeddedBytes() ByteView {
    return .{ .ptr = &embedded_nnue_stub, .len = 1 };
}

// Read the affine-layer byte sizes from the weight-storage owner, which lays the
// per-bucket arena out from the same table -- one source, so the parse destination
// and the arena layout cannot disagree.
fn layerBiasesBytes(idx: usize) usize {
    return weight_storage.layer_biases_bytes[idx];
}
fn layerWeightsBytes(idx: usize) usize {
    return weight_storage.layer_weights_bytes[idx];
}

pub fn load(root_directory: []const u8, requested_path: []const u8) void {
    const default_name = default_eval_file_name;
    const evalfile_path = if (requested_path.len == 0) default_name else requested_path;
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

/// Export the loaded net. `filename` is null when the `export_net` command carried no
/// argument, which is the only case where the default name may be substituted.
pub fn save(filename: ?[]const u8) SaveResult {
    const default_name = default_eval_file_name;
    const current_name = nnCurrent();

    var actual_filename: []const u8 = undefined;
    if (filename) |given| {
        actual_filename = given;
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

pub fn verify(requested_path: []const u8) VerifyResult {
    const default_name = default_eval_file_name;
    const current_name = nnCurrent();
    const evalfile_path = if (requested_path.len == 0) default_name else requested_path;

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

    // Fix the verification dims by the NNUE architecture (sizeof the
    // FeatureTransformer + NetworkArchitecture*LayerStacks; the static InputDimensions /
    // TransformedFeatureDimensions / FC_0_OUTPUTS / FC_1_OUTPUTS). Fixed constants.
    const info = VerifyInfo{
        .size_bytes = 115115520,
        .input_dimensions = 86896,
        .transformed_dimensions = 1024,
        .fc0_outputs = 32,
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

// Alias back the accessors for the Zig-owned EvalFile dynamic state + weight
// storage, which live in the nnue_weight_storage leaf now (shared owner for the
// inference and I/O paths), so the call sites here stay unqualified.
const nnCurrent = weight_storage.nnCurrent;
const nnDescription = weight_storage.nnDescription;
const markInitialized = weight_storage.markInitialized;
const setLoadedState = weight_storage.setLoadedState;
const equalCurrentName = weight_storage.equalCurrentName;
const ftStorage = weight_storage.ftStorage;
const layerStorage = weight_storage.layerStorage;
const layerPtr = weight_storage.layerPtr;
pub const ftPtr = weight_storage.ftPtr;

fn loadUserNet(dir: []const u8, evalfile_path: []const u8) void {
    markInitialized();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    const io = threaded.io();

    const path = std.mem.concat(arena, u8, &.{ dir, evalfile_path }) catch return;
    const file = openFileForRead(io, path) catch return;
    defer file.close(io);

    const stat = file.stat(io) catch return;

    // Map the blob instead of read-then-copy where the OS can (POSIX): the parse
    // walks every byte exactly once and copies the weights into the Zig-owned
    // storage, so a read-only MAP_PRIVATE view faults the shared page-cache pages
    // in as the parse reaches them -- no transient heap buffer the size of the
    // net and no second full pass over its bytes. Windows and an unmappable
    // filesystem fall back to the buffered read below.
    if (builtin.os.tag != .windows and stat.size > 0) {
        const len: usize = @intCast(stat.size);
        const raw = std.c.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
        if (raw != std.c.MAP_FAILED) {
            defer _ = std.c.munmap(@alignCast(raw), len);
            const mapped: [*]const u8 = @ptrCast(raw);
            _ = loadNetworkBytes(mapped[0..len], evalfile_path);
            return;
        }
    }

    var reader_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);

    const bytes = reader.interface.readAlloc(arena, stat.size) catch return;
    _ = loadNetworkBytes(bytes, evalfile_path);
}

fn loadInternal() void {
    markInitialized();

    const default_name = default_eval_file_name;
    _ = loadNetworkBytes(viewToSlice(networkEmbeddedBytes()), default_name);
}

// Gather one layer stack's biases/weights slices (fc_0/fc_1/fc_2).
fn layerArrays(bucket: usize) ?struct { b: [3][]const u8, w: [3][]const u8 } {
    var b: [3][]const u8 = undefined;
    var w: [3][]const u8 = undefined;
    for (0..3) |idx| {
        const bp = layerPtr(bucket, idx, .biases) orelse return null;
        const wp = layerPtr(bucket, idx, .weights) orelse return null;
        b[idx] = bp[0..layerBiasesBytes(idx)];
        w[idx] = wp[0..layerWeightsBytes(idx)];
    }
    return .{ .b = b, .w = w };
}

// Serialize the feature transformer into `out` (write_parameters blob,
// including the leading component hash).
fn emitFt(out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    const ft: [*]const u8 = @ptrCast(ftPtr() orelse return error.NoNetwork);
    try nnue_parse.serializeFeatureTransformer(
        ft[0..nnue_dims.ft_total_bytes],
        nnue_hash.featureTransformerHashValue(),
        out,
        a,
    );
}

// Serialize one layer stack into `out`.
fn emitLayer(bucket: usize, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    const arr = layerArrays(bucket) orelse return error.NoNetwork;
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

    emitFt(&blob, a) catch return false;
    writer.interface.writeAll(blob.items) catch return false;

    var bucket: usize = 0;
    while (bucket < layer_stacks) : (bucket += 1) {
        blob.clearRetainingCapacity();
        emitLayer(bucket, &blob, a) catch return false;
        writer.interface.writeAll(blob.items) catch return false;
    }

    writer.interface.flush() catch return false;

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
    var header: [12]u8 = @splat(0);
    writeU32LeInto(header[0..4], network_version);
    writeU32LeInto(header[4..8], hash_value);
    writeU32LeInto(header[8..12], @intCast(description.len));
    try writer.writeAll(&header);
    try writer.writeAll(description);
}

fn viewToSlice(view: ByteView) []const u8 {
    return view.ptr[0..view.len];
}

fn boolToU8(value: bool) u8 {
    return if (value) 1 else 0;
}

fn allocMessage(comptime fmt: []const u8, args: anytype) ?[]u8 {
    return std.fmt.allocPrint(std.heap.c_allocator, fmt, args) catch null;
}

test {
    @import("std").testing.refAllDecls(@This());
}
