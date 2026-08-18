// Read a .nnue file into the live network weights.
//
// Split from network.zig on the 500-line lint, along the seam that file already had: this is
// everything that walks an UNTRUSTED file -- the header, the feature transformer, the layer
// stacks -- while network.zig keeps the option-facing face (load / save / verify). The
// dependency runs network -> here only, so the pair is not a file cycle.
//
// Every offset below comes out of the file, so each reader returns null/false rather than
// trusting a length the file states.

const std = @import("std");
const nnue_parse = @import("nnue_parse.zig");
const nnue_dims = @import("nnue_dimensions");
const nnue_hash = @import("nnue_hash.zig");
const weight_storage = @import("nnue_weight_storage.zig");

const setLoadedState = weight_storage.setLoadedState;
const nnCurrent = weight_storage.nnCurrent;
const ftStorage = weight_storage.ftStorage;
const layerStorage = weight_storage.layerStorage;
const layerPtr = weight_storage.layerPtr;

pub const network_version: u32 = 0x6A448AFA; // upstream nnue_common.h Version (post-merge format)

const layer_stacks: usize = 8;

fn layerBiasesBytes(idx: usize) usize {
    return weight_storage.layer_biases_bytes[idx];
}
fn layerWeightsBytes(idx: usize) usize {
    return weight_storage.layer_weights_bytes[idx];
}

const Header = struct {
    hash_value: u32,
    description: []const u8,
};

// Report a load that failed AFTER it began overwriting the live weights, and stop naming the
// net it replaced.
//
// The parse reads each section straight into the live object, so a file with a well-formed
// header and a wrong section later leaves the network half this file and half the last one.
// Leaving the recorded name alone then made that record a lie, and everything downstream
// trusts it: `verify` compares it against the option and passes, and `load` SKIPS a path equal
// to it -- so re-selecting the net the engine says it has was a silent no-op and the engine
// went on evaluating with the wreck. Measured on a net truncated to 5% with bytes xor'd inside
// the feature transformer: startpos `eval` read +0.10 after re-selecting the shipped net,
// against +0.03 clean.
//
// Clearing it makes the record true. The engine then either reloads on the next selection or
// refuses to search, which are the two states this seam already knows how to be in.
fn clearLoadedAfterPartialWrite() bool {
    setLoadedState("", "");
    return false;
}

pub fn loadNetworkBytes(bytes: []const u8, current_name: []const u8) bool {
    var offset: usize = 0;
    // Nothing below has written yet, so a net rejected here leaves the previous one intact and
    // correctly named. Do NOT clear on these two: a bad `setoption EvalFile` would then take a
    // working engine down with it.
    const header = readHeader(bytes, &offset) orelse return false;
    if (header.hash_value != nnue_hash.networkHashValue()) {
        return false;
    }

    if (!readFeatureTransformer(bytes, &offset)) {
        return clearLoadedAfterPartialWrite();
    }

    var bucket: usize = 0;
    while (bucket < layer_stacks) : (bucket += 1) {
        if (!readLayer(bucket, bytes, &offset)) {
            return clearLoadedAfterPartialWrite();
        }
    }

    if (offset != bytes.len) {
        return clearLoadedAfterPartialWrite();
    }

    setLoadedState(current_name, header.description);
    // Trust the parse as the sole source of weights; correctness is verified end-to-end
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

// Transform one output bucket (FT). Reads weights from the feature-transformer
// storage above (always resident after a network load) and runs the Zig accumulator
// transform.

// Parse the feature transformer into the Zig-owned storage and return the bytes
// consumed (leading component hash + the LEB-coded params). The parse is the sole
// source (the eval gates verify the weights end-to-end, and the offset==bytes.len check
// at the end of loadNetworkBytes verifies the consumed count).
fn loadFt(blob: []const u8) usize {
    const dst_ptr = ftStorage(nnue_dims.ft_total_bytes) orelse
        @panic("feature-transformer storage allocation failed");
    const dst = dst_ptr[0..nnue_dims.ft_total_bytes];
    // Report a malformed net as 0 consumed rather than aborting: the file is user input, and
    // readFeatureTransformer already treats 0 as "reject this net".
    return nnue_parse.parseFeatureTransformer(blob, dst) orelse 0;
}

fn readFeatureTransformer(bytes: []const u8, offset: *usize) bool {
    const remaining = bytes[offset.*..];
    const consumed = loadFt(remaining);
    if (consumed == 0 or consumed > remaining.len) {
        return false;
    }
    offset.* += consumed;
    return true;
}

// Parse this bucket's affine layers into the Zig-owned storage (skip the leading
// architecture hash, then fc_0/fc_1/fc_2 biases+scrambled weights) and return the bytes
// consumed. The parse is the sole source.
fn loadLayer(bucket: usize, blob: []const u8) usize {
    var pos: usize = 4; // architecture component hash
    // A blob too short to hold the hash cannot be sliced past it; reject rather than trap.
    if (blob.len < pos) return 0;
    for (0..3) |idx| {
        const wb = layerWeightsBytes(idx);
        const bb = layerBiasesBytes(idx);
        const bdst = layerStorage(bucket, idx, .biases, bb) orelse
            @panic("affine-layer storage allocation failed");
        const wdst = layerStorage(bucket, idx, .weights, wb) orelse
            @panic("affine-layer storage allocation failed");
        // Report a malformed net as 0 consumed; readLayer already treats that as a reject.
        // fc_1/fc_2 (idx > 0) read paired-activation output on the pair tier, so their
        // weights take the extra input interleave (serializeLayer inverts the same flag).
        const used = nnue_parse.parseLayer(
            blob[pos..],
            bdst[0..bb],
            wdst[0..wb],
            nnue_parse.scrambled_activations and idx > 0,
        ) orelse return 0;
        pos += used;
        if (pos > blob.len) return 0;
    }
    return pos;
}

fn readLayer(bucket: usize, bytes: []const u8, offset: *usize) bool {
    const remaining = bytes[offset.*..];
    const consumed = loadLayer(bucket, remaining);
    if (consumed == 0 or consumed > remaining.len) {
        return false;
    }
    offset.* += consumed;
    return true;
}

fn readU32Le(bytes: []const u8, offset: *usize) ?u32 {
    if (offset.* + 4 > bytes.len) {
        return null;
    }

    const start = offset.*;
    offset.* += 4;
    return @as(u32, bytes[start]) | (@as(u32, bytes[start + 1]) << 8) | (@as(u32, bytes[start + 2]) << 16) | (@as(u32, bytes[start + 3]) << 24);
}

pub fn writeU32LeInto(bytes: []u8, value: u32) void {
    bytes[0] = @intCast(value & 0xff);
    bytes[1] = @intCast((value >> 8) & 0xff);
    bytes[2] = @intCast((value >> 16) & 0xff);
    bytes[3] = @intCast((value >> 24) & 0xff);
}

// ---- tests ------------------------------------------------------------------

test "a load that half-overwrote the live net stops reporting the one it replaced" {
    // The parse reads each section straight into the LIVE weights, so a file with a
    // well-formed header and a wrong section after it leaves the network half this file and
    // half the last one. If the recorded name survives that, everything downstream trusts a
    // lie: `verify` compares it against the option and passes, and `load` skips a path equal
    // to it -- so re-selecting the net the engine says it has is a silent no-op.
    //
    // Build the blob rather than reading a fixture. A test that needs a net on disk SKIPS
    // when it is absent, and a silent skip is how a gate stops being one.
    const a = std.testing.allocator;
    var blob = std.ArrayList(u8).empty;
    defer blob.deinit(a);
    const desc = "half a net";
    var word: [4]u8 = undefined;
    writeU32LeInto(&word, network_version);
    try blob.appendSlice(a, &word);
    writeU32LeInto(&word, nnue_hash.networkHashValue());
    try blob.appendSlice(a, &word);
    writeU32LeInto(&word, @intCast(desc.len));
    try blob.appendSlice(a, &word);
    try blob.appendSlice(a, desc);
    // ...and nothing else, so the header and the hash both pass and the feature transformer
    // is the first thing to fail -- which is the first thing that writes.

    setLoadedState("previous.nnue", "the net that was loaded");
    try std.testing.expect(!loadNetworkBytes(blob.items, "half.nnue"));
    try std.testing.expectEqualStrings("", nnCurrent());

    // The other half of the contract: a net refused BEFORE anything is written must leave the
    // previous one named, because it is still live and still correct. A bad `setoption
    // EvalFile` must not take a working engine down with it.
    setLoadedState("previous.nnue", "the net that was loaded");
    writeU32LeInto(blob.items[4..8], nnue_hash.networkHashValue() ^ 1); // wrong hash
    try std.testing.expect(!loadNetworkBytes(blob.items, "wrong-hash.nnue"));
    try std.testing.expectEqualStrings("previous.nnue", nnCurrent());

    setLoadedState("", "");
}

test {
    std.testing.refAllDecls(@This());
}
