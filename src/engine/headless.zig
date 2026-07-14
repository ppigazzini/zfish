//! Engine-only build/test root.
//!
//! Referencing every engine/ module here compiles the entire engine dependency
//! graph in isolation. By the headless invariant (the `headless` gate) that graph
//! contains no platform/ or shell/ module, so building this file proves -- at the
//! compiler and linker level, not just structurally -- that the engine is a
//! standalone search+eval library. Built + tested by `zig build engine`.
//!
//! The list mirrors the engine-zone modules in build.zig's module_specs; the
//! matching build step imports the same set, so a new engine module is added in
//! both places (or the `headless` gate / this build stay honest about the graph).

comptime {
    _ = @import("bitboard");
    _ = @import("board_core");
    _ = @import("correction_bundle");
    _ = @import("evaluate");
    _ = @import("fen");
    _ = @import("fen_parse");
    _ = @import("history");
    _ = @import("legality");
    _ = @import("limits_type");
    _ = @import("move_do");
    _ = @import("movegen");
    _ = @import("movepick");
    _ = @import("network");
    _ = @import("network_holder");
    _ = @import("nnue_acc_rowops");
    _ = @import("nnue_accumulator");
    _ = @import("nnue_feature");
    _ = @import("nnue_ft");
    _ = @import("nnue_misc");
    _ = @import("nnue_refresh_cache");
    _ = @import("option_source");
    _ = @import("output_sink");
    _ = @import("page_alloc");
    _ = @import("position");
    _ = @import("position_lifecycle");
    _ = @import("position_query");
    _ = @import("position_snapshot");
    _ = @import("position_storage");
    _ = @import("position_types");
    _ = @import("repetition");
    _ = @import("root_move");
    _ = @import("root_move_build");
    _ = @import("score");
    _ = @import("search");
    _ = @import("search_acc");
    _ = @import("search_common");
    _ = @import("search_ctx");
    _ = @import("search_driver");
    _ = @import("search_emit");
    _ = @import("search_id");
    _ = @import("search_manager");
    _ = @import("search_setup");
    _ = @import("search_types");
    _ = @import("shared_histories");
    _ = @import("shared_histories_map");
    _ = @import("shared_history");
    _ = @import("shared_history_types");
    _ = @import("shared_state");
    _ = @import("state_list");
    _ = @import("state_setup");
    _ = @import("tb_source");
    _ = @import("thread_ops");
    _ = @import("time_source");
    _ = @import("timeman");
    _ = @import("tt");
    _ = @import("tt_types");
    _ = @import("uci_move");
    _ = @import("uci_wdl");
    _ = @import("worker_construct");
    _ = @import("worker_histories");
    _ = @import("worker_layout");
    _ = @import("zobrist");
}

test {
    // Compilation of the imports above is the invariant. This keeps the file a
    // runnable test artifact so `zig build engine` exercises the standalone graph.
    @import("std").testing.refAllDecls(@This());
}
