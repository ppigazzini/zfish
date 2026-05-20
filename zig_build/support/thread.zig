const std = @import("std");

const value_none: c_int = 32002;
const value_infinite: c_int = 32001;
const value_tb_win_in_max_ply: c_int = 31507;
const value_tb_loss_in_max_ply: c_int = -31507;
const max_thread_summaries: usize = 1024;

pub const ThreadSummary = extern struct {
    pv0_raw: u16,
    score_is_bound: u8,
    pv_has_more_than_two: u8,
    score: c_int,
    root_depth: c_int,
};

pub const ByteView = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub const TbConfig = extern struct {
    cardinality: c_int,
    root_in_tb: u8,
    use_rule50: u8,
    probe_depth: c_int,
};

extern fn zfish_threadpool_wait_main_thread(pool: *anyopaque) void;
extern fn zfish_threadpool_reset_start_state(pool: *anyopaque, ponder_mode: u8) void;
extern fn zfish_movegen_generate_legal(
    pos: *const anyopaque,
    out_moves: [*]u16,
) usize;
extern fn zfish_limits_ponder_mode(limits: *const anyopaque) u8;
extern fn zfish_limits_searchmove_count(limits: *const anyopaque) usize;
extern fn zfish_limits_searchmove_text(limits: *const anyopaque, index: usize) ByteView;
extern fn zfish_uci_to_move_raw(pos: *const anyopaque, text_ptr: [*]const u8, text_len: usize) u16;
extern fn zfish_move_none_raw() u16;
extern fn zfish_root_moves_create(move_raws: ?[*]const u16, count: usize) *anyopaque;
extern fn zfish_root_moves_destroy(root_moves: *anyopaque) void;
extern fn zfish_threadpool_rank_root_moves(
    options: *const anyopaque,
    pos: *anyopaque,
    root_moves: *anyopaque,
) TbConfig;
extern fn zfish_threadpool_thread_count(pool: *const anyopaque) usize;
extern fn zfish_threadpool_thread_at(pool: *anyopaque, index: usize) *anyopaque;
extern fn zfish_threadpool_reset_clear_state(pool: *anyopaque) void;
extern fn zfish_thread_nodes_searched(thread: *const anyopaque) u64;
extern fn zfish_thread_tb_hits(thread: *const anyopaque) u64;
extern fn zfish_thread_fill_summary(thread: *const anyopaque, out: *ThreadSummary) void;
extern fn zfish_thread_run_root_setup(
    thread: *anyopaque,
    limits: *const anyopaque,
    root_moves: *const anyopaque,
    pos: *const anyopaque,
    setup_state: *const anyopaque,
    tb_config: TbConfig,
) void;
extern fn zfish_thread_clear_worker(thread: *anyopaque) void;
extern fn zfish_thread_wait_for_search_finished(thread: *anyopaque) void;
extern fn zfish_thread_start_searching(thread: *anyopaque) void;
extern fn zfish_thread_ensure_network_replicated(thread: *anyopaque) void;

pub fn nextPowerOfTwo(count: u64) usize {
    if (count <= 1)
        return 1;
    return @as(usize, 2) << @as(u6, @intCast(63 - @clz(count - 1)));
}

pub fn pickBestThread(summaries: [*]const ThreadSummary, count: usize) usize {
    var best_index: usize = 0;
    var min_score: c_int = value_none;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (summaries[index].score < min_score)
            min_score = summaries[index].score;
    }

    index = 0;
    while (index < count) : (index += 1) {
        const best = summaries[best_index];
        const current = summaries[index];
        const best_vote = voteForMove(summaries, count, best.pv0_raw, min_score);
        const current_vote = voteForMove(summaries, count, current.pv0_raw, min_score);
        const best_decisive = isDecisiveBest(best);
        const current_decisive = isDecisiveBest(current);
        const better_voting_value =
            threadVotingValue(current, min_score) * @as(c_int, current.pv_has_more_than_two) > threadVotingValue(best, min_score) * @as(c_int, best.pv_has_more_than_two);

        if (best_decisive) {
            if (current_decisive and absInt(current.score) > absInt(best.score)) {
                best_index = index;
            }
        } else if (current_decisive or
            (!isLoss(current.score) and
                (current_vote > best_vote or (current_vote == best_vote and better_voting_value))))
        {
            best_index = index;
        }
    }

    return best_index;
}

pub fn startThinking(
    pool: *anyopaque,
    options: *const anyopaque,
    pos: *anyopaque,
    limits: *const anyopaque,
    setup_state: *const anyopaque,
) void {
    zfish_threadpool_wait_main_thread(pool);
    zfish_threadpool_reset_start_state(pool, zfish_limits_ponder_mode(limits));

    var legal_move_buffer: [256]u16 = undefined;
    const legal_move_count = zfish_movegen_generate_legal(pos, legal_move_buffer[0..].ptr);
    const legal_moves = legal_move_buffer[0..legal_move_count];
    const none_raw = zfish_move_none_raw();

    var selected_moves = std.ArrayList(u16).empty;
    defer selected_moves.deinit(std.heap.c_allocator);

    const searchmove_count = zfish_limits_searchmove_count(limits);
    var index: usize = 0;
    while (index < searchmove_count) : (index += 1) {
        const move_text = zfish_limits_searchmove_text(limits, index);
        const text_ptr = move_text.ptr orelse continue;
        const move_raw = zfish_uci_to_move_raw(pos, text_ptr, move_text.len);
        if (move_raw != none_raw and containsMove(legal_moves, move_raw)) {
            selected_moves.append(std.heap.c_allocator, move_raw) catch @panic("OOM");
        }
    }

    if (selected_moves.items.len == 0) {
        selected_moves.appendSlice(std.heap.c_allocator, legal_moves) catch @panic("OOM");
    }

    const move_raws_ptr: ?[*]const u16 = if (selected_moves.items.len == 0)
        null
    else
        selected_moves.items.ptr;
    const root_moves = zfish_root_moves_create(move_raws_ptr, selected_moves.items.len);
    defer zfish_root_moves_destroy(root_moves);

    const tb_config = zfish_threadpool_rank_root_moves(options, pos, root_moves);
    const thread_count = zfish_threadpool_thread_count(pool);

    index = 0;
    while (index < thread_count) : (index += 1) {
        const thread = zfish_threadpool_thread_at(pool, index);
        zfish_thread_run_root_setup(thread, limits, root_moves, pos, setup_state, tb_config);
    }

    index = 0;
    while (index < thread_count) : (index += 1) {
        const thread = zfish_threadpool_thread_at(pool, index);
        zfish_thread_wait_for_search_finished(thread);
    }

    const main_thread = zfish_threadpool_thread_at(pool, 0);
    zfish_thread_start_searching(main_thread);
}

pub fn clear(pool: *anyopaque) void {
    const thread_count = zfish_threadpool_thread_count(pool);
    if (thread_count == 0) {
        return;
    }

    var index: usize = 0;
    while (index < thread_count) : (index += 1) {
        zfish_thread_clear_worker(zfish_threadpool_thread_at(pool, index));
    }

    index = 0;
    while (index < thread_count) : (index += 1) {
        zfish_thread_wait_for_search_finished(zfish_threadpool_thread_at(pool, index));
    }

    zfish_threadpool_reset_clear_state(pool);
}

pub fn nodesSearched(pool: *anyopaque) u64 {
    const thread_count = zfish_threadpool_thread_count(pool);
    var total: u64 = 0;
    var index: usize = 0;
    while (index < thread_count) : (index += 1) {
        total += zfish_thread_nodes_searched(zfish_threadpool_thread_at(pool, index));
    }
    return total;
}

pub fn tbHits(pool: *anyopaque) u64 {
    const thread_count = zfish_threadpool_thread_count(pool);
    var total: u64 = 0;
    var index: usize = 0;
    while (index < thread_count) : (index += 1) {
        total += zfish_thread_tb_hits(zfish_threadpool_thread_at(pool, index));
    }
    return total;
}

pub fn bestThreadIndex(pool: *anyopaque) usize {
    const thread_count = zfish_threadpool_thread_count(pool);
    if (thread_count == 0) {
        return 0;
    }
    if (thread_count > max_thread_summaries) {
        @panic("thread summary buffer too small");
    }

    var summaries: [max_thread_summaries]ThreadSummary = undefined;
    var index: usize = 0;
    while (index < thread_count) : (index += 1) {
        zfish_thread_fill_summary(zfish_threadpool_thread_at(pool, index), &summaries[index]);
    }

    return pickBestThread(&summaries, thread_count);
}

pub fn startSearching(pool: *anyopaque) void {
    const thread_count = zfish_threadpool_thread_count(pool);
    var index: usize = 1;
    while (index < thread_count) : (index += 1) {
        zfish_thread_start_searching(zfish_threadpool_thread_at(pool, index));
    }
}

pub fn waitForSearchFinished(pool: *anyopaque) void {
    const thread_count = zfish_threadpool_thread_count(pool);
    var index: usize = 1;
    while (index < thread_count) : (index += 1) {
        zfish_thread_wait_for_search_finished(zfish_threadpool_thread_at(pool, index));
    }
}

pub fn ensureNetworkReplicated(pool: *anyopaque) void {
    const thread_count = zfish_threadpool_thread_count(pool);
    var index: usize = 0;
    while (index < thread_count) : (index += 1) {
        zfish_thread_ensure_network_replicated(zfish_threadpool_thread_at(pool, index));
    }
}

fn voteForMove(
    summaries: [*]const ThreadSummary,
    count: usize,
    move_raw: u16,
    min_score: c_int,
) c_int {
    var vote: c_int = 0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (summaries[index].pv0_raw == move_raw)
            vote += threadVotingValue(summaries[index], min_score);
    }
    return vote;
}

fn threadVotingValue(summary: ThreadSummary, min_score: c_int) c_int {
    return (summary.score - min_score + 14) * summary.root_depth;
}

fn isWin(score: c_int) bool {
    return score >= value_tb_win_in_max_ply;
}

fn isLoss(score: c_int) bool {
    return score <= value_tb_loss_in_max_ply;
}

fn isDecisive(score: c_int) bool {
    return isWin(score) or isLoss(score);
}

fn isDecisiveBest(summary: ThreadSummary) bool {
    return summary.score != -value_infinite and isDecisive(summary.score) and summary.score_is_bound == 0;
}

fn absInt(value: c_int) c_int {
    return if (value < 0) -value else value;
}

fn containsMove(moves: []const u16, target: u16) bool {
    for (moves) |move_raw| {
        if (move_raw == target) {
            return true;
        }
    }

    return false;
}
