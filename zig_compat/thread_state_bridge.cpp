#define private public
#include "uci.h"
#include "search.h"
#undef private
#include "engine.h"
#include "memory.h"
#include "misc.h"
#include "movegen.h"
#include "numa.h"
#include "position.h"
#include "score.h"
#include "thread.h"
#include "types.h"
#include "ucioption.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <bitset>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <initializer_list>
#include <iterator>
#include <map>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

extern "C" {
struct ZfishThreadSummary {
    std::uint16_t pv0_raw;
    std::uint8_t  score_is_bound;
    std::uint8_t  pv_has_more_than_two;
    int           score;
    int           root_depth;
};

struct ZfishTbConfig {
    int          cardinality;
    std::uint8_t root_in_tb;
    std::uint8_t use_rule50;
    int          probe_depth;
};

struct ZfishRankedRootMove {
    std::uint16_t raw_move;
    int           tb_rank;
    int           tb_score;
};

using ZfishOpaqueCallback = void (*)(void*);
}

namespace Stockfish {
namespace {

struct ZfishSearchMoveView {
    const unsigned char* ptr;
    std::size_t          len;
};

// Bridge-only view that mirrors Search::Worker layout for Zig-owned start_thinking setup.
struct WorkerBridgeLayout {
    ButterflyHistory                 mainHistory;
    LowPlyHistory                    lowPlyHistory;
    CapturePieceToHistory            captureHistory;
    ContinuationHistory              continuationHistory[2][2];
    CorrectionHistory<Continuation>  continuationCorrectionHistory;
    TTMoveHistory                    ttMoveHistory;
    SharedHistories&                 sharedHistory;
    Search::LimitsType               limits;
    std::size_t                      pvIdx;
    std::size_t                      pvLast;
    std::atomic<std::uint64_t>       nodes;
    std::atomic<std::uint64_t>       tbHits;
    std::atomic<std::uint64_t>       bestMoveChanges;
    int                              selDepth;
    int                              nmpMinPly;
    Value                            optimism[COLOR_NB];
    Position                         rootPos;
    StateInfo                        rootState;
    Search::RootMoves                rootMoves;
    Depth                            rootDepth;
    Value                            rootDelta;
    Search::PVMoves                  lastIterationPV;
    std::size_t                      threadIdx;
    std::size_t                      numaThreadIdx;
    std::size_t                      numaTotal;
    NumaReplicatedAccessToken        numaAccessToken;
    std::array<int, MAX_MOVES>       reductions;
    std::unique_ptr<Search::ISearchManager> manager;
    Tablebases::Config               tbConfig;
    const OptionsMap&                options;
    ThreadPool&                      threads;
    TranspositionTable&              tt;
    const LazyNumaReplicatedSystemWide<Eval::NNUE::Network>& network;
    Eval::NNUE::AccumulatorStack     accumulatorStack;
    Eval::NNUE::AccumulatorCaches    refreshTable;
};

static_assert(sizeof(WorkerBridgeLayout) == sizeof(Search::Worker));
static_assert(alignof(WorkerBridgeLayout) == alignof(Search::Worker));

WorkerBridgeLayout* bridge_worker(Thread* thread) {
    return reinterpret_cast<WorkerBridgeLayout*>(thread->worker.get());
}

}  // namespace

extern "C" {

std::uint8_t zfish_limits_ponder_mode(const void* limits_ptr) {
    return static_cast<const Search::LimitsType*>(limits_ptr)->ponderMode ? 1 : 0;
}

std::size_t zfish_limits_perft_value(const void* limits_ptr) {
    return static_cast<std::size_t>(static_cast<const Search::LimitsType*>(limits_ptr)->perft);
}

std::size_t zfish_limits_searchmove_count(const void* limits_ptr) {
    return static_cast<const Search::LimitsType*>(limits_ptr)->searchmoves.size();
}

ZfishSearchMoveView zfish_limits_searchmove_text(const void* limits_ptr, std::size_t index) {
    const auto& searchmoves = static_cast<const Search::LimitsType*>(limits_ptr)->searchmoves;
    assert(index < searchmoves.size());
    const auto& text = searchmoves[index];
    return {reinterpret_cast<const unsigned char*>(text.data()), text.size()};
}

void* zfish_root_moves_create_ranked(const ZfishRankedRootMove* items, std::size_t count) {
    auto root_moves = std::make_unique<Search::RootMoves>();
    root_moves->reserve(count);
    for (std::size_t index = 0; index < count; ++index)
    {
        root_moves->emplace_back(Move(items[index].raw_move));
        auto& root_move = root_moves->back();
        root_move.tbRank = items[index].tb_rank;
        root_move.tbScore = Value(items[index].tb_score);
    }
    return root_moves.release();
}

void zfish_root_moves_destroy(void* root_moves_ptr) {
    delete static_cast<Search::RootMoves*>(root_moves_ptr);
}

std::size_t zfish_threadpool_thread_count(const void* pool_ptr) {
    return static_cast<const ThreadPool*>(pool_ptr)->size();
}

std::size_t zfish_threadpool_bound_node_count(const void* pool_ptr) {
    return static_cast<const ThreadPool*>(pool_ptr)->boundThreadToNumaNode.size();
}

std::size_t zfish_threadpool_bound_node_at(const void* pool_ptr, std::size_t index) {
    const auto* pool = static_cast<const ThreadPool*>(pool_ptr);
    assert(index < pool->boundThreadToNumaNode.size());
    return pool->boundThreadToNumaNode[index];
}

std::size_t zfish_numa_context_node_count(const void* numa_context_ptr) {
    return static_cast<const NumaReplicationContext*>(numa_context_ptr)
      ->get_numa_config()
      .num_numa_nodes();
}

std::size_t zfish_numa_context_cpus_in_node(const void* numa_context_ptr, std::size_t node) {
    const auto& cfg = static_cast<const NumaReplicationContext*>(numa_context_ptr)->get_numa_config();
    assert(node < cfg.num_numa_nodes());
    return cfg.num_cpus_in_numa_node(node);
}

void* zfish_threadpool_thread_at(void* pool_ptr, std::size_t index) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    assert(index < pool->size());
    return (*(pool->begin() + static_cast<std::ptrdiff_t>(index))).get();
}

void zfish_threadpool_set_stop_flag(void* pool_ptr, std::uint8_t stop) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->stop = stop != 0;
}

void zfish_threadpool_main_manager_set_stop_on_ponderhit(void* pool_ptr,
                                                         std::uint8_t stop_on_ponderhit) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->stopOnPonderhit = stop_on_ponderhit != 0;
}

void zfish_threadpool_main_manager_set_ponder(void* pool_ptr, std::uint8_t ponder_mode) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->ponder = ponder_mode != 0;
}

void zfish_threadpool_set_increase_depth(void* pool_ptr, std::uint8_t increase_depth) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->increaseDepth = increase_depth != 0;
}

std::uint8_t zfish_options_syzygy_50_move_rule(const void* options_ptr) {
    return static_cast<std::uint8_t>(
      bool((*static_cast<const OptionsMap*>(options_ptr))["Syzygy50MoveRule"]));
}

int zfish_options_syzygy_probe_depth(const void* options_ptr) {
    return int((*static_cast<const OptionsMap*>(options_ptr))["SyzygyProbeDepth"]);
}

int zfish_options_syzygy_probe_limit(const void* options_ptr) {
    return int((*static_cast<const OptionsMap*>(options_ptr))["SyzygyProbeLimit"]);
}

void* zfish_position_create() { return new Position(); }

void zfish_position_destroy(void* pos_ptr) { delete static_cast<Position*>(pos_ptr); }

void zfish_thread_run_callback(void* thread_ptr, ZfishOpaqueCallback callback, void* context) {
    auto* thread = static_cast<Thread*>(thread_ptr);
    thread->run_custom_job([callback, context]() { callback(context); });
}

void zfish_thread_worker_set_limits(void* thread_ptr, const void* limits_ptr) {
    auto* worker = bridge_worker(static_cast<Thread*>(thread_ptr));
    worker->limits = *static_cast<const Search::LimitsType*>(limits_ptr);
}

void zfish_thread_worker_reset_root_setup_state(void* thread_ptr) {
    auto* worker = bridge_worker(static_cast<Thread*>(thread_ptr));
    worker->nodes           = 0;
    worker->tbHits          = 0;
    worker->bestMoveChanges = 0;
    worker->nmpMinPly       = 0;
    worker->rootDepth       = 0;
}

void zfish_thread_worker_set_root_moves(void* thread_ptr, const void* root_moves_ptr) {
    auto* worker = bridge_worker(static_cast<Thread*>(thread_ptr));
    worker->rootMoves = *static_cast<const Search::RootMoves*>(root_moves_ptr);
}

void zfish_thread_worker_set_root_position(void*                thread_ptr,
                                           const unsigned char* fen_ptr,
                                           std::size_t          fen_len,
                                           std::uint8_t         chess960) {
    auto* worker = bridge_worker(static_cast<Thread*>(thread_ptr));
    const auto fen = std::string(reinterpret_cast<const char*>(fen_ptr), fen_len);
    worker->rootPos.set(fen, chess960 != 0, &worker->rootState);
}

void zfish_thread_worker_set_root_state(void* thread_ptr, const void* setup_state_ptr) {
    auto* worker = bridge_worker(static_cast<Thread*>(thread_ptr));
    worker->rootState = *static_cast<const StateInfo*>(setup_state_ptr);
}

void zfish_thread_worker_set_tb_config(void* thread_ptr, ZfishTbConfig config) {
    auto* worker = bridge_worker(static_cast<Thread*>(thread_ptr));
    worker->tbConfig = Tablebases::Config{config.cardinality, config.root_in_tb != 0,
                                          config.use_rule50 != 0,
                                          Depth(config.probe_depth)};
}

void zfish_thread_wait_for_search_finished(void* thread_ptr) {
    static_cast<Thread*>(thread_ptr)->wait_for_search_finished();
}

void zfish_thread_start_searching(void* thread_ptr) {
    static_cast<Thread*>(thread_ptr)->start_searching();
}

std::uint64_t zfish_thread_nodes_searched(const void* thread_ptr) {
    return static_cast<const Thread*>(thread_ptr)->worker->nodes.load(std::memory_order_relaxed);
}

std::uint64_t zfish_thread_tb_hits(const void* thread_ptr) {
    return static_cast<const Thread*>(thread_ptr)->worker->tbHits.load(std::memory_order_relaxed);
}

void zfish_thread_fill_summary(const void* thread_ptr, ZfishThreadSummary* out) {
    const auto* thread = static_cast<const Thread*>(thread_ptr);
    const auto& root_move = thread->worker->rootMoves[0];
    out->pv0_raw = root_move.pv[0].raw();
    out->score_is_bound = root_move.score_is_bound();
    out->pv_has_more_than_two = root_move.pv.size() > 2;
    out->score = root_move.score;
    out->root_depth = int(thread->worker->rootDepth);
}

void zfish_thread_clear_worker(void* thread_ptr) {
    static_cast<Thread*>(thread_ptr)->clear_worker();
}

void zfish_thread_ensure_network_replicated(void* thread_ptr) {
    static_cast<Thread*>(thread_ptr)->ensure_network_replicated();
}

void zfish_threadpool_main_manager_reset_best_previous_average_score(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->bestPreviousAverageScore = VALUE_INFINITE;
}

void zfish_threadpool_main_manager_reset_previous_time_reduction(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->previousTimeReduction    = 0.85;
}

void zfish_threadpool_main_manager_reset_calls_count(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->callsCnt                 = 0;
}

void zfish_threadpool_main_manager_reset_best_previous_score(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->bestPreviousScore        = VALUE_INFINITE;
}

void zfish_threadpool_main_manager_reset_original_time_adjust(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->originalTimeAdjust       = -1;
}

void zfish_threadpool_main_manager_clear_timeman(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->tm.clear();
}

void zfish_threadpool_reset_for_reconfigure(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->threads.clear();
    pool->boundThreadToNumaNode.clear();
}

void zfish_threadpool_bound_nodes_assign(void* pool_ptr,
                                         const std::size_t* nodes_ptr,
                                         std::size_t        count) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    if (!nodes_ptr || count == 0)
    {
        pool->boundThreadToNumaNode.clear();
        return;
    }

    pool->boundThreadToNumaNode.assign(nodes_ptr, nodes_ptr + count);
}

std::size_t zfish_shared_state_threads_value(const void* shared_state_ptr) {
    const auto& shared_state = *static_cast<const Search::SharedState*>(shared_state_ptr);
    return static_cast<std::size_t>(shared_state.options["Threads"]);
}

std::uint8_t zfish_shared_state_numa_policy_mode(const void* shared_state_ptr) {
    const auto&       shared_state = *static_cast<const Search::SharedState*>(shared_state_ptr);
    const std::string numa_policy(shared_state.options["NumaPolicy"]);

    if (numa_policy == "none")
        return 0;
    if (numa_policy == "auto")
        return 1;
    return 2;
}

void zfish_shared_state_clear_histories(const void* shared_state_ptr) {
    const auto& shared_state = *static_cast<const Search::SharedState*>(shared_state_ptr);
    shared_state.sharedHistories.clear();
}

void zfish_shared_state_insert_history(const void*  shared_state_ptr,
                                       const void*  numa_config_ptr,
                                       std::size_t  numa_index,
                                       std::size_t  size,
                                       std::uint8_t do_bind) {
    const auto& shared_state = *static_cast<const Search::SharedState*>(shared_state_ptr);
    const auto& numa_config  = *static_cast<const NumaConfig*>(numa_config_ptr);

    auto insert = [&]() { shared_state.sharedHistories.try_emplace(numa_index, size); };
    if (do_bind != 0)
        numa_config.execute_on_numa_node(numa_index, insert);
    else
        insert();
}

std::uint8_t zfish_numa_config_suggests_binding_threads(const void* numa_config_ptr,
                                                        std::size_t requested) {
    return static_cast<const NumaConfig*>(numa_config_ptr)->suggests_binding_threads(requested)
             ? std::uint8_t{1}
             : std::uint8_t{0};
}

std::size_t zfish_numa_config_distribute_threads_among_nodes(const void* numa_config_ptr,
                                                             std::size_t requested,
                                                             std::size_t* out_nodes) {
    const auto distribution =
      static_cast<const NumaConfig*>(numa_config_ptr)->distribute_threads_among_numa_nodes(
        requested);
    if (out_nodes)
        std::copy(distribution.begin(), distribution.end(), out_nodes);
    return distribution.size();
}

std::size_t zfish_numa_config_node_count(const void* numa_config_ptr) {
    return static_cast<const NumaConfig*>(numa_config_ptr)->num_numa_nodes();
}

void zfish_numa_config_execute_on_numa_node(const void*       numa_config_ptr,
                                                                                        std::size_t       numa_index,
                                                                                        ZfishOpaqueCallback callback,
                                                                                        void*             context) {
        const auto& numa_config = *static_cast<const NumaConfig*>(numa_config_ptr);
        numa_config.execute_on_numa_node(numa_index, [&]() { callback(context); });
}

void zfish_threadpool_add_main_thread_bound(void*       pool_ptr,
                                                                                        const void* numa_config_ptr,
                                                                                        const void* shared_state_ptr,
                                                                                        const void* update_context_ptr,
                                                                                        std::size_t  thread_id,
                                                                                        std::size_t  idx_in_numa,
                                                                                        std::size_t  total_numa,
                                                                                        std::size_t  numa_id) {
        auto& pool = *static_cast<ThreadPool*>(pool_ptr);
        auto& shared_state =
            *const_cast<Search::SharedState*>(static_cast<const Search::SharedState*>(shared_state_ptr));
        const auto& numa_config = *static_cast<const NumaConfig*>(numa_config_ptr);
        const auto& update_context =
            *static_cast<const Search::SearchManager::UpdateContext*>(update_context_ptr);

        pool.threads.emplace_back(std::make_unique<Thread>(
            shared_state, std::make_unique<Search::SearchManager>(update_context), thread_id,
            idx_in_numa, total_numa, OptionalThreadToNumaNodeBinder(numa_config, numa_id)));
}

void zfish_threadpool_add_main_thread_unbound(void*       pool_ptr,
                                                                                            const void* shared_state_ptr,
                                                                                            const void* update_context_ptr,
                                                                                            std::size_t  thread_id,
                                                                                            std::size_t  idx_in_numa,
                                                                                            std::size_t  total_numa,
                                                                                            std::size_t  numa_id) {
        auto& pool = *static_cast<ThreadPool*>(pool_ptr);
        auto& shared_state =
            *const_cast<Search::SharedState*>(static_cast<const Search::SharedState*>(shared_state_ptr));
        const auto& update_context =
            *static_cast<const Search::SearchManager::UpdateContext*>(update_context_ptr);

        pool.threads.emplace_back(std::make_unique<Thread>(
            shared_state, std::make_unique<Search::SearchManager>(update_context), thread_id,
            idx_in_numa, total_numa, OptionalThreadToNumaNodeBinder(numa_id)));
}

void zfish_threadpool_add_worker_thread_bound(void*       pool_ptr,
                                                                                            const void* numa_config_ptr,
                                                                                            const void* shared_state_ptr,
                                                                                            std::size_t  thread_id,
                                                                                            std::size_t  idx_in_numa,
                                                                                            std::size_t  total_numa,
                                                                                            std::size_t  numa_id) {
        auto& pool = *static_cast<ThreadPool*>(pool_ptr);
        auto& shared_state =
            *const_cast<Search::SharedState*>(static_cast<const Search::SharedState*>(shared_state_ptr));
        const auto& numa_config = *static_cast<const NumaConfig*>(numa_config_ptr);

        pool.threads.emplace_back(std::make_unique<Thread>(
            shared_state, std::make_unique<Search::NullSearchManager>(), thread_id, idx_in_numa,
            total_numa, OptionalThreadToNumaNodeBinder(numa_config, numa_id)));
}

void zfish_threadpool_add_worker_thread_unbound(void*       pool_ptr,
                                                                                                const void* shared_state_ptr,
                                                                                                std::size_t  thread_id,
                                                                                                std::size_t  idx_in_numa,
                                                                                                std::size_t  total_numa,
                                                                                                std::size_t  numa_id) {
        auto& pool = *static_cast<ThreadPool*>(pool_ptr);
        auto& shared_state =
            *const_cast<Search::SharedState*>(static_cast<const Search::SharedState*>(shared_state_ptr));

        pool.threads.emplace_back(std::make_unique<Thread>(
            shared_state, std::make_unique<Search::NullSearchManager>(), thread_id, idx_in_numa,
            total_numa, OptionalThreadToNumaNodeBinder(numa_id)));
}

struct ZfishPendingStateListStorage {
    StateListPtr states;

    ZfishPendingStateListStorage() :
        states(new std::deque<StateInfo>(1)) {}
};

void* zfish_engine_state_list_storage_create() {
    return new (std::nothrow) ZfishPendingStateListStorage();
}

void zfish_engine_state_list_storage_destroy(void* storage_ptr) {
    delete static_cast<ZfishPendingStateListStorage*>(storage_ptr);
}

void* zfish_engine_state_list_storage_reset(void* storage_ptr) {
    auto& storage = *static_cast<ZfishPendingStateListStorage*>(storage_ptr);
    storage.states = StateListPtr(new std::deque<StateInfo>(1));
    return &storage.states->back();
}

void* zfish_engine_state_list_storage_push(void* storage_ptr) {
    auto& storage = *static_cast<ZfishPendingStateListStorage*>(storage_ptr);
    storage.states->emplace_back();
    return &storage.states->back();
}

std::uint8_t zfish_engine_state_list_storage_has_states(const void* storage_ptr) {
    return static_cast<const ZfishPendingStateListStorage*>(storage_ptr)->states ? std::uint8_t{1}
                                                                                 : std::uint8_t{0};
}

void zfish_threadpool_setup_states_adopt_from_storage(void* pool_ptr, void* storage_ptr) {
    auto& pool = *static_cast<ThreadPool*>(pool_ptr);
    auto& storage = *static_cast<ZfishPendingStateListStorage*>(storage_ptr);
    pool.setupStates = std::move(storage.states);
}

void zfish_threadpool_setup_states_adopt_from_slot(void* pool_ptr, void* states_slot_ptr) {
    auto& pool = *static_cast<ThreadPool*>(pool_ptr);
    auto& states = *static_cast<StateListPtr*>(states_slot_ptr);

    pool.setupStates = std::move(states);
}

std::uint8_t zfish_threadpool_has_setup_states(const void* pool_ptr) {
    const auto& pool = *static_cast<const ThreadPool*>(pool_ptr);
    return pool.setupStates ? std::uint8_t{1} : std::uint8_t{0};
}

const void* zfish_threadpool_setup_state_back(const void* pool_ptr) {
    const auto& pool = *static_cast<const ThreadPool*>(pool_ptr);
    if (!pool.setupStates)
        return nullptr;

    return &pool.setupStates->back();
}

const char* zfish_engine_position_set(void*                pos_ptr,
                                      const unsigned char* fen_ptr,
                                      std::size_t          fen_len,
                                      std::uint8_t         chess960_enabled,
                                      void*                state_ptr) {
    const std::string fen(reinterpret_cast<const char*>(fen_ptr), fen_len);
    const auto        err = static_cast<Position*>(pos_ptr)->set(
      fen, chess960_enabled != 0, static_cast<StateInfo*>(state_ptr));
    if (!err.has_value())
        return nullptr;

    const auto message = std::string(err->what());
    auto*      buffer  = static_cast<char*>(std::malloc(message.size() + 1));
    if (!buffer)
        std::abort();
    std::memcpy(buffer, message.c_str(), message.size() + 1);
    return buffer;
}

void zfish_engine_position_do_move(void* pos_ptr, std::uint16_t move_raw, void* state_ptr) {
    static_cast<Position*>(pos_ptr)->do_move(Move(move_raw), *static_cast<StateInfo*>(state_ptr));
}

}  // extern "C"

}  // namespace Stockfish
