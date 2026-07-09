// LimitsType + SearchMoveText — the UCI `go` search-limits record and its
// searchmoves element (M17.10 god-module split: lifted out of graph_layout, whose
// re-export keeps `graph_layout.LimitsType` / `.SearchMoveText` resolving for the
// go-command call chain). A standalone POD leaf over std — no reference to the
// worker/thread graph, so it carries no cycle.

const std = @import("std");

// A Zig-owned UCI searchmove text record (M17.6): replaces the libc++ std::string
// element the searchmoves vector used to hold. Fixed 8-byte record -- a length byte
// plus up to 7 chars ("e2e4", "e7e8q"). uci.goParsed writes these; the startThinking
// move filter reads them by plain field access, so no foreign-runtime std::string SSO
// byte layout is decoded any more. The searchmoves header stays a {begin,end,cap}
// usize triple (the LimitsType slot layout is contractual, comptime-checked below),
// but it now points at Zig-owned records, not a C++ container.
pub const SearchMoveText = extern struct {
    len: u8,
    text: [7]u8,
};

// The LimitsType object (120 bytes): a leading 24-byte std::vector<std::string>
// `searchmoves` (POD-opaque here), then seven 8-byte TimePoints
// (time[2]/inc[2]/npmsec/movetime/startTime) ending at 80, then the search-mode
// ints (movestogo/depth/mate/perft/infinite), nodes, and ponderMode. workerSetLimits
// copies the POD fields, so any layout error here breaks bench (gate-verified).
pub const LimitsType = struct {
    searchmoves: [3]usize, // {begin, end, cap} over Zig SearchMoveText records (M17.6)
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
    /// Number of searchmoves entries: (end-begin) over the SearchMoveText record
    /// size. begin/end are the typed usize header words.
    pub inline fn searchmoveCount(self: *const LimitsType) usize {
        const begin = self.searchmoves[0];
        const end = self.searchmoves[1];
        return (end - begin) / @sizeOf(SearchMoveText);
    }
};

comptime {
    // Native struct (M16.8 de-mirror): Zig owns the field order; workerSetLimits copies
    // the POD fields explicitly (not a byte range), so only the fit in the Worker's
    // 120-byte limits slot (worker_off.limits..pv_idx) is contractual.
    std.debug.assert(@sizeOf(LimitsType) <= 120);
}
