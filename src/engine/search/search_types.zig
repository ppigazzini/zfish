// Define the search POD data types.
//
// Collect the plain-data structs the search driver threads through: the per-ply
// SearchStack, the correction-history bundle, and the PV / RootMove types.
// position.zig re-exports all four, so its call sites are unchanged.

const std = @import("std");
const root_move = @import("root_move");
const worker_histories = @import("worker_histories");
const correction_bundle = @import("correction_bundle");

// List the scalar fields the search helpers read. Keep the two continuation pointers as
// concrete PieceToHistory pages; keep pv opaque (resolved through the PV type).
pub const SearchStack = struct {
    pv: ?*root_move.PVMoves,
    continuation_history: ?*worker_histories.PieceToHistory,
    continuation_correction_history: ?*worker_histories.PieceToHistory,
    ply: i32,
    current_move: u16,
    excluded_move: u16,
    static_eval: i32,
    stat_score: i32,
    move_count: i32,
    in_check: bool,
    tt_pv: bool,
    tt_hit: bool,
    follow_pv: bool,
    cutoff_cnt: i32,
    reduction: i32,
};

// Re-export CorrectionBundle from the correction_bundle module as the
// canonical name.
pub const CorrectionBundle = correction_bundle.CorrectionBundle;

// Re-export PVMoves + RootMove from the single canonical definition in
// support/root_move.zig. The search indexes the rootMoves array
// (handed over by worker_state) through these; the canonical def
// carries the same field order/types/offsets plus the search's methods.
pub const PVMoves = root_move.PVMoves;
pub const RootMove = root_move.RootMove;

/// Name the three kinds of node the search has -- upstream's `template<NodeType>`
/// with `Root`, `PV` and `NonPV`.
///
/// The search used to carry this as two independent `comptime` booleans,
/// `pv_node` and `root_node`, which admit FOUR combinations where the search
/// means three. A root is always searched with a full window, so a non-PV root
/// names nothing, and no call site ever produced one -- an illegal state that
/// was representable in the signature of the hottest function in the engine.
///
/// One `comptime` parameter of this type makes it unwriteable: there is no
/// fourth variant to name. Zig takes an enum as a `comptime` parameter
/// directly, so this needs no marker types and no generic machinery.
pub const NodeKind = enum {
    root,
    pv,
    non_pv,

    /// Report whether the node is searched on a full window. A root always is.
    pub inline fn isPv(self: NodeKind) bool {
        return self != .non_pv;
    }

    /// Report whether the node is the root of the search.
    pub inline fn isRoot(self: NodeKind) bool {
        return self == .root;
    }

    /// Name the kind of the quiescence node entered FROM this one. Dropping into
    /// quiescence loses rootness and keeps PV-ness, so the root's own quiescence
    /// node is an ordinary PV node rather than a second root. Carrying that here
    /// is what lets `qsearchImpl` refuse `.root` outright.
    pub inline fn quiescent(self: NodeKind) NodeKind {
        return if (self.isPv()) .pv else .non_pv;
    }
};

test "NodeKind: a root is a PV node, and quiescence is never a root" {
    const testing = @import("std").testing;
    try testing.expect(NodeKind.root.isPv());
    try testing.expect(NodeKind.pv.isPv());
    try testing.expect(!NodeKind.non_pv.isPv());

    try testing.expect(NodeKind.root.isRoot());
    try testing.expect(!NodeKind.pv.isRoot());

    // Rootness is lost, PV-ness is kept.
    try testing.expectEqual(NodeKind.pv, NodeKind.root.quiescent());
    try testing.expectEqual(NodeKind.pv, NodeKind.pv.quiescent());
    try testing.expectEqual(NodeKind.non_pv, NodeKind.non_pv.quiescent());
    inline for (.{ NodeKind.root, NodeKind.pv, NodeKind.non_pv }) |k| {
        try testing.expect(!k.quiescent().isRoot());
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
