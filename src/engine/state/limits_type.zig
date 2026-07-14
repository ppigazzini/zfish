// LimitsType + SearchMoveText — the UCI `go` search-limits record and its
// searchmoves element. worker_layout re-exports them so `worker_layout.LimitsType` /
// `.SearchMoveText` keep resolving for the go-command call chain. A standalone POD
// leaf over std.

const std = @import("std");

// A Zig-owned UCI searchmove text record: a length byte plus up to 7 chars ("e2e4",
// "e7e8q"). uci.goParsed writes these; the startThinking move filter reads them by plain
// field access. A plain Zig struct (not `extern`): the layout is not a C-ABI or byte-
// serialization contract -- it is only ever a typed `[]SearchMoveText` element -- and
// with two u8-based fields Zig lays it out as the same contiguous 8 bytes regardless.
pub const SearchMoveText = struct {
    len: u8,
    text: [7]u8,
};

// The LimitsType object: the `searchmoves` list, seven TimePoints
// (time[2]/inc[2]/npmsec/movetime/startTime), the search-mode ints
// (movestogo/depth/mate/perft/infinite), nodes, and ponderMode. workerSetLimits
// copies the POD fields, so any layout error here breaks bench (gate-verified).
pub const LimitsType = struct {
    searchmoves: []SearchMoveText, // the `go searchmoves` list
    time: [2]i64, // time[WHITE], time[BLACK]
    inc: [2]i64, // inc[WHITE], inc[BLACK]
    npmsec: i64,
    movetime: i64,
    start_time: i64,
    movestogo: i32,
    depth: i32,
    mate: i32,
    perft: i32,
    infinite: i32,
    nodes: u64,
    ponder_mode: u8,

    pub inline fn fromPtr(p: *anyopaque) *LimitsType {
        return @ptrCast(@alignCast(p));
    }
    pub inline fn fromAddr(addr: usize) *LimitsType {
        return @ptrFromInt(addr);
    }
    pub inline fn ponderMode(self: *const LimitsType) bool {
        return self.ponder_mode != 0;
    }
    pub inline fn perftValue(self: *const LimitsType) usize {
        return @intCast(self.perft);
    }
    /// Number of `go searchmoves` entries -- the slice length.
    pub inline fn searchmoveCount(self: *const LimitsType) usize {
        return self.searchmoves.len;
    }
};

comptime {
    // Zig owns the field order; workerSetLimits copies the POD fields explicitly (not
    // a byte range), so only the fit in the Worker's 120-byte limits slot
    // (worker_off.limits..pv_idx) is contractual.
    std.debug.assert(@sizeOf(LimitsType) <= 120);
}

test {
    @import("std").testing.refAllDecls(@This());
}
