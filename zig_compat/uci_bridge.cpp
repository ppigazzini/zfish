/*
  Stockfish, a UCI chess playing engine derived from Glaurung 2.1
  Copyright (C) 2004-2026 The Stockfish developers (see AUTHORS file)

  Stockfish is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  Stockfish is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

#include "uci.h"

#include <algorithm>
#include <array>
#include <bitset>
#include <cctype>
#include <cstdlib>
#include <initializer_list>
#include <iterator>
#include <map>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "benchmark.h"
#include "engine.h"
#include "memory.h"
#include "misc.h"
#include "movegen.h"
#include "numa.h"
#include "position.h"
#include "score.h"
#include "search.h"
#include "tune.h"
#include "types.h"
#include "ucioption.h"

#define ZFISH_POSITION_BRIDGE_SKIP_COMPUTE_MATERIAL_KEY
#define ZFISH_POSITION_BRIDGE_SKIP_ENDGAME_SET
#define ZFISH_POSITION_BRIDGE_SKIP_FEN
#include "../src/position.cpp"

/*
  Stockfish, a UCI chess playing engine derived from Glaurung 2.1
  Copyright (C) 2004-2026 The Stockfish developers (see AUTHORS file)

  Stockfish is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  Stockfish is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

#include "engine.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iosfwd>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <ostream>
#include <sstream>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

#define INCBIN_SILENCE_BITCODE_WARNING
#include "incbin/incbin.h"

#include "evaluate.h"
#include "misc.h"
#include "nnue/network.h"
#include "nnue/nnue_architecture.h"
#include "nnue/nnue_common.h"
#include "nnue/nnue_misc.h"
#include "numa.h"
#include "perft.h"
#include "position.h"
#include "search.h"
#include "shm.h"
#include "syzygy/tbprobe.h"
#include "types.h"
#include "uci.h"
#include "ucioption.h"

#define PieceToChar engine_bridge_tbprobe_piece_to_char
#define ZFISH_TBPROBE_BRIDGE_SKIP_DTZ_BEFORE_ZEROING
#define ZFISH_TBPROBE_BRIDGE_SKIP_ADD
#include "../src/syzygy/tbprobe.cpp"
#undef PieceToChar

#include "nnue/nnue_accumulator.h"
#include "nnue/features/full_threats.h"
#include "nnue/features/half_ka_v2_hm.h"

#include <new>

#include "bitboard.h"
#include "nnue/nnue_feature_transformer.h"  // IWYU pragma: keep
#include "nnue/simd.h"

#if !defined(UNIVERSAL_BINARY) && !defined(_MSC_VER) && !defined(NNUE_EMBEDDING_OFF)
INCBIN(EmbeddedNNUE, EvalFileDefaultName);
#elif defined(UNIVERSAL_BINARY)
    #define WEAK_SYM __attribute__((weak))
extern const unsigned char gEmbeddedNNUEData[] WEAK_SYM = {
    #embed EvalFileDefaultName
};
extern const unsigned int gEmbeddedNNUESize WEAK_SYM = sizeof(gEmbeddedNNUEData);
#else
const unsigned char gEmbeddedNNUEData[1] = {0x0};
const unsigned int  gEmbeddedNNUESize    = 1;
#endif

namespace Stockfish {

namespace NN = Eval::NNUE;

constexpr int MaxHashMB  = Is64Bit ? 33554432 : 2048;
int           MaxThreads = std::max(1024, 4 * int(get_hardware_concurrency()));

constexpr NumaAutoPolicy DefaultNumaPolicy = BundledL3Policy{32};

extern "C" {
struct ZfishCountPair {
    std::size_t current;
    std::size_t total;
};

const char* zfish_engine_format_numa_info(const unsigned char* config_ptr, std::size_t config_len);
const char* zfish_engine_format_thread_binding(const ZfishCountPair* pairs_ptr, std::size_t pair_count);
const char* zfish_engine_format_thread_allocation(std::size_t          thread_count,
                                                  const unsigned char* binding_ptr,
                                                  std::size_t          binding_len);
const char* zfish_engine_format_network_status(std::size_t          replica_index,
                                               std::uint8_t        status,
                                               const unsigned char* error_ptr,
                                               std::size_t          error_len);
struct ZfishEvalTraceInput {
    const unsigned char* inner_trace_ptr;
    std::size_t          inner_trace_len;
    int                  nnue_internal_value;
    int                  nnue_white_cp;
    int                  final_white_cp;
};

struct ZfishNnueTraceInput {
    std::uint8_t side_to_move_white;
    std::size_t  bucket_count;
    std::size_t  correct_bucket;
    const int*   psqt_cp;
    const int*   positional_cp;
};

const char* zfish_eval_format_trace(ZfishEvalTraceInput input);
const char* zfish_nnue_format_trace(ZfishNnueTraceInput input);
const char* zfish_tbprobe_build_code(const unsigned char* piece_types_ptr, std::size_t piece_count);
int         zfish_tbprobe_dtz_before_zeroing(int wdl);
const char*   zfish_misc_engine_info_text();
}

namespace {

struct Tie: public std::streambuf {

    Tie(std::streambuf* b, std::streambuf* l) :
        buf(b),
        logBuf(l) {}

    int sync() override { return logBuf->pubsync(), buf->pubsync(); }
    int overflow(int c) override { return log(buf->sputc(char(c)), "<< "); }
    int underflow() override { return buf->sgetc(); }
    int uflow() override { return log(buf->sbumpc(), ">> "); }

    std::streambuf *buf, *logBuf;

    int log(int c, const char* prefix) {
        static int last = '\n';

        if (last == '\n')
            logBuf->sputn(prefix, 3);

        return last = logBuf->sputc(char(c));
    }
};

class Logger {

    Logger() :
        in(std::cin.rdbuf(), file.rdbuf()),
        out(std::cout.rdbuf(), file.rdbuf()) {}
    ~Logger() { start(""); }

    std::ofstream file;
    Tie           in, out;

   public:
    static void start(const std::string& fname) {
        static Logger l;

        if (l.file.is_open())
        {
            std::cout.rdbuf(l.out.buf);
            std::cin.rdbuf(l.in.buf);
            l.file.close();
        }

        if (!fname.empty())
        {
            l.file.open(fname, std::ifstream::out);

            if (!l.file.is_open())
            {
                std::cerr << "Unable to open debug log file " << fname << std::endl;
                exit(EXIT_FAILURE);
            }

            std::cin.rdbuf(&l.in);
            std::cout.rdbuf(&l.out);
        }
    }
};

std::string take_string_and_free_engine_required(const char* rendered) {
    if (!rendered)
        std::abort();

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

int dtz_before_zeroing(WDLScore wdl) { return zfish_tbprobe_dtz_before_zeroing(int(wdl)); }

}  // namespace

void TBTables::add(const std::vector<PieceType>& pieces) {
#include "uci_bridge/tb_tables_add_code.inc"

#include "uci_bridge/tb_tables_add_dtz_probe.inc"

#include "uci_bridge/tb_tables_add_wdl_probe.inc"

#include "uci_bridge/tb_tables_add_table_update.inc"
}





namespace Eval::NNUE {

struct NetworkBridgeAccess {
#include "uci_bridge/network_bridge_eval_file.inc"

#include "uci_bridge/network_bridge_load_user_net.inc"

#include "uci_bridge/network_bridge_load_internal.inc"

#include "uci_bridge/network_bridge_save_named.inc"

#include "uci_bridge/network_bridge_feature_transformer.inc"

#include "uci_bridge/network_bridge_layer.inc"
};







namespace Detail {

template<typename T>
#include "uci_bridge/network_detail_read_parameters.inc"

template<typename T>
#include "uci_bridge/network_detail_write_parameters.inc"

}  // namespace Detail



extern "C" {
struct ZfishByteView {
    const unsigned char* ptr;
    std::size_t          len;
};

struct ZfishNetworkSaveResult {
    std::uint8_t saved;
    const char*  message;
};

struct ZfishNetworkVerifyResult {
    std::uint8_t should_exit;
    const char*  message;
};

struct ZfishNetworkEvalOutput {
    int psqt;
    int positional;
};

struct ZfishNetworkVerifyInfo {
    std::size_t size_bytes;
    std::size_t input_dimensions;
    std::size_t transformed_dimensions;
    int         fc0_outputs;
    int         fc1_outputs;
};

struct ZfishNetworkTraceOutput {
    int         psqt[LayerStacks];
    int         positional[LayerStacks];
    std::size_t correct_bucket;
};

void zfish_network_load(void*                network,
                        const unsigned char* root_directory_ptr,
                        std::size_t          root_directory_len,
                        const unsigned char* evalfile_path_ptr,
                        std::size_t          evalfile_path_len);
ZfishNetworkSaveResult zfish_network_save(const void*          network,
                                          std::uint8_t         has_filename,
                                          const unsigned char* filename_ptr,
                                          std::size_t          filename_len);
ZfishNetworkVerifyResult zfish_network_verify(const void*          network,
                                              const unsigned char* evalfile_path_ptr,
                                              std::size_t          evalfile_path_len);
ZfishNetworkEvalOutput zfish_network_evaluate(const void* network,
                                              const void* pos,
                                              void*       accumulator_stack,
                                              void*       cache);
ZfishNetworkTraceOutput zfish_network_trace_evaluate(const void* network,
                                                     const void* pos,
                                                     void*       accumulator_stack,
                                                     void*       cache);

#include "uci_bridge/network_default_name.inc"

#include "uci_bridge/network_current_name.inc"

#include "uci_bridge/network_load_user_net.inc"

#include "uci_bridge/network_load_internal_export.inc"

#include "uci_bridge/network_save_named_export.inc"

#include "uci_bridge/network_piece_count.inc"

ZfishNetworkEvalOutput zfish_network_evaluate_bucket_raw(const void* network_ptr,
                                                         const void* pos_ptr,
                                                         void*       accumulator_stack_ptr,
                                                         void*       cache_ptr,
                                                         std::size_t bucket) {
#include "uci_bridge/network_evaluate_bucket_raw_prelude.inc"

#include "uci_bridge/network_evaluate_bucket_raw_transform.inc"

#include "uci_bridge/network_evaluate_bucket_raw_return.inc"
}

#include "uci_bridge/network_verify_info.inc"
}











void Network::load(const std::string& rootDirectory, std::string evalfilePath) {
#include "uci_bridge/network_member_load.inc"
}

bool Network::save(const std::optional<std::string>& filename) const {
#include "uci_bridge/network_member_save_prelude.inc"

#include "uci_bridge/network_member_save_message.inc"

#include "uci_bridge/network_member_save_return.inc"
}

NetworkOutput Network::evaluate(const Position&    pos,
                                AccumulatorStack&  accumulatorStack,
                                AccumulatorCaches& cache) const {
#include "uci_bridge/network_member_evaluate.inc"
}

void Network::verify(std::string                                  evalfilePath,
                     const std::function<void(std::string_view)>& f) const {
#include "uci_bridge/network_member_verify_prelude.inc"

#include "uci_bridge/network_member_verify_message.inc"

#include "uci_bridge/network_member_verify_exit.inc"
}

NnueEvalTrace Network::trace_evaluate(const Position&    pos,
                                      AccumulatorStack&  accumulatorStack,
                                      AccumulatorCaches& cache) const {
#include "uci_bridge/network_member_trace_prelude.inc"

#include "uci_bridge/network_member_trace_loop.inc"

#include "uci_bridge/network_member_trace_return.inc"
}

void Network::load_user_net(const std::string& dir, const std::string& evalfilePath) {
#include "uci_bridge/network_member_load_user_net_prelude.inc"

#include "uci_bridge/network_member_load_user_net_apply.inc"
}

void Network::load_internal() {
#include "uci_bridge/network_member_load_internal_memory_buffer.inc"

#include "uci_bridge/network_member_load_internal_setup.inc"

#include "uci_bridge/network_member_load_internal_apply.inc"
}

void Network::initialize() {
#include "uci_bridge/network_member_initialize.inc"
}

bool Network::save(std::ostream&      stream,
                   const std::string& name,
                   const std::string& netDescription) const {
#include "uci_bridge/network_member_save_name_guard.inc"

#include "uci_bridge/network_member_save_write_return.inc"
}

std::optional<std::string> Network::load(std::istream& stream) {
#include "uci_bridge/network_member_load_stream_prelude.inc"

#include "uci_bridge/network_member_load_stream_return.inc"
}

std::size_t Network::get_content_hash() const {
#include "uci_bridge/network_member_hash_guard.inc"

#include "uci_bridge/network_member_hash_body.inc"
}

bool Network::read_header(std::istream& stream, std::uint32_t* hashValue, std::string* desc) const {
#include "uci_bridge/network_member_read_header_prelude.inc"

#include "uci_bridge/network_member_read_header_tail.inc"
}

bool Network::write_header(std::ostream&      stream,
                           std::uint32_t      hashValue,
                           const std::string& desc) const {
#include "uci_bridge/network_member_write_header.inc"
}

bool Network::read_parameters(std::istream& stream, std::string& netDescription) {
#include "uci_bridge/network_member_read_parameters_prelude.inc"

    for (std::size_t i = 0; i < LayerStacks; ++i)
    {
        if (!Detail::read_parameters(stream, network[i]))
            return false;
    }
    return stream && stream.peek() == std::ios::traits_type::eof();
}

bool Network::write_parameters(std::ostream& stream, const std::string& netDescription) const {
    if (!write_header(stream, Network::hash, netDescription))
        return false;
    if (!Detail::write_parameters(stream, featureTransformer))
        return false;
    for (std::size_t i = 0; i < LayerStacks; ++i)
    {
        if (!Detail::write_parameters(stream, network[i]))
            return false;
    }
    return bool(stream);
}

}  // namespace Eval::NNUE
}




























/*
  Stockfish, a UCI chess playing engine derived from Glaurung 2.1
  Copyright (C) 2004-2026 The Stockfish developers (see AUTHORS file)

  Stockfish is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  Stockfish is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>

#include "tt.h"
#include "thread.h"

#define ZFISH_SEARCH_BRIDGE_SKIP_TO_CORRECTED_STATIC_EVAL
#define ZFISH_SEARCH_BRIDGE_SKIP_VALUE_DRAW
#define ZFISH_SEARCH_BRIDGE_SKIP_REDUCTION
#include "../src/search.cpp"

extern "C" {
struct ZfishTimemanInput {
    std::int64_t time_us;
    std::int64_t inc_us;
    std::int64_t start_time;
    std::int64_t npmsec;
    std::int64_t move_overhead;
    std::int64_t available_nodes;
    std::int64_t current_optimum_time;
    std::int64_t current_maximum_time;
    int          movestogo;
    int          ply;
    double       original_time_adjust;
    std::uint8_t ponder;
};

struct ZfishTimemanOutput {
    std::int64_t time_us;
    std::int64_t inc_us;
    std::int64_t start_time;
    std::int64_t npmsec;
    std::int64_t available_nodes;
    std::int64_t optimum_time;
    std::int64_t maximum_time;
    double       original_time_adjust;
    std::uint8_t use_nodes_time;
};

struct ZfishMoveScoreInput {
    std::uint16_t raw_move;
    std::uint8_t  check_bonus;
    std::uint8_t  from_threatened;
    std::uint8_t  to_threatened;
    std::uint8_t  capture_stage;
    int           capture_history;
    int           captured_piece_value;
    int           main_history;
    int           pawn_history;
    int           continuation_sum;
    int           piece_value;
    int           low_ply_bonus;
};

struct ZfishMoveSortEntry {
    std::uint16_t raw_move;
    std::uint16_t reserved;
    int           value;
};

struct ZfishEvalInput {
    int psqt;
    int positional;
    int optimism;
    int material;
    int rule50_count;
    int value_tb_loss_in_max_ply;
    int value_tb_win_in_max_ply;
};

struct ZfishMovegenSnapshot {
    std::uint8_t  side_to_move;
    std::uint64_t pieces_all;
    std::uint64_t pieces_by_color[2];
    std::uint64_t pieces_by_type[8];
    std::uint8_t  king_square[2];
    std::uint8_t  ep_square;
    std::uint8_t  castling_rights;
    std::uint8_t  castling_impeded[16];
    std::uint8_t  castling_rook_square[16];
    std::uint64_t checkers;
    std::uint64_t blockers_for_king[2];
};

struct ZfishTtEntry {
    std::uint16_t key16;
    std::uint8_t  depth8;
    std::uint8_t  gen_bound8;
    std::uint16_t move16;
    std::int16_t  value16;
    std::int16_t  eval16;
};

struct ZfishTtCluster {
    ZfishTtEntry entry[3];
    char         padding[2];
};

struct ZfishTtReadOutput {
    std::uint16_t move16;
    std::int16_t  value16;
    std::int16_t  eval16;
    int           depth;
    std::uint8_t  bound;
    std::uint8_t  is_pv;
};

struct ZfishTtProbeOutput {
    std::uint8_t      found;
    std::uint8_t      writer_index;
    ZfishTtReadOutput data;
};

int zfish_search_to_corrected_static_eval(int v, int cv);
int zfish_search_value_draw(std::size_t nodes);
int zfish_search_reduction(const int* reductions,
                           int        depth,
                           int        move_number,
                           int        delta,
                           int        root_delta,
                           std::uint8_t improving);
ZfishTimemanOutput zfish_timeman_init(ZfishTimemanInput input);
void zfish_movepick_score_moves(std::uint8_t               kind,
                                const ZfishMoveScoreInput* inputs,
                                std::size_t                count,
                                ZfishMoveSortEntry*        outputs);
void zfish_movepick_partial_insertion_sort(ZfishMoveSortEntry* entries,
                                           std::size_t         count,
                                           int                 limit);
int zfish_eval_compute_value(ZfishEvalInput input);
std::size_t zfish_movegen_generate_captures(const void* pos, std::uint16_t* move_list);
std::size_t zfish_movegen_generate_quiets(const void* pos, std::uint16_t* move_list);
std::size_t zfish_movegen_generate_evasions(const void* pos, std::uint16_t* move_list);
std::size_t zfish_movegen_generate_non_evasions(const void* pos, std::uint16_t* move_list);
void        zfish_movegen_fill_snapshot(const void* pos_ptr, ZfishMovegenSnapshot* out);
std::uint64_t zfish_movegen_attacks(std::uint8_t piece_type,
                                    std::uint8_t square,
                                    std::uint64_t occupied);
std::uint64_t zfish_movegen_between(std::uint8_t from, std::uint8_t to);
void zfish_tt_entry_save(ZfishTtEntry* entry,
                         std::uint64_t key,
                         int           value,
                         std::uint8_t  pv,
                         std::uint8_t  bound,
                         int           depth,
                         int           depth_none,
                         std::uint16_t move16,
                         int           eval,
                         std::uint8_t  curr_generation);
ZfishTtReadOutput zfish_tt_entry_read(const ZfishTtEntry* entry, int depth_none);
std::uint8_t      zfish_tt_entry_relative_age(const ZfishTtEntry* entry,
                                              std::uint8_t        curr_generation);
std::uint8_t      zfish_tt_generation_next(std::uint8_t curr_generation);
int               zfish_tt_hashfull(const ZfishTtCluster* clusters,
                                    std::size_t           cluster_count,
                                    std::uint8_t          generation,
                                    int                   max_age);
std::size_t       zfish_tt_first_entry_index(std::uint64_t key, std::size_t cluster_count);
ZfishTtProbeOutput zfish_tt_probe(const ZfishTtCluster* cluster,
                                  std::uint64_t         key,
                                  std::uint8_t          generation,
                                  int                   depth_none);

struct ZfishThreadSummary {
    std::uint16_t pv0_raw;
    std::uint8_t  score_is_bound;
    std::uint8_t  pv_has_more_than_two;
    int           score;
    int           root_depth;
};

std::size_t zfish_thread_next_power_of_two(std::uint64_t count);
std::size_t zfish_thread_pick_best_thread(const ZfishThreadSummary* summaries,
                                          std::size_t               count);
}

namespace Stockfish {

namespace {

enum Stages {
    MAIN_TT,
    CAPTURE_INIT,
    GOOD_CAPTURE,
    QUIET_INIT,
    GOOD_QUIET,
    BAD_CAPTURE,
    BAD_QUIET,

    EVASION_TT,
    EVASION_INIT,
    EVASION,

    PROBCUT_TT,
    PROBCUT_INIT,
    PROBCUT,

    QSEARCH_TT,
    QCAPTURE_INIT,
    QCAPTURE
};

Value to_corrected_static_eval(const Value v, const int cv) {
    return Value(zfish_search_to_corrected_static_eval(v, cv));
}

Value value_draw(size_t nodes) { return Value(zfish_search_value_draw(nodes)); }

void partial_insertion_sort(ExtMove* begin, ExtMove* end, int limit) {
    const auto count = static_cast<std::size_t>(end - begin);
    ZfishMoveSortEntry entries[MAX_MOVES]{};

    for (std::size_t i = 0; i < count; ++i)
    {
        entries[i].raw_move = begin[i].raw();
        entries[i].value    = begin[i].value;
    }

    zfish_movepick_partial_insertion_sort(entries, count, limit);

    for (std::size_t i = 0; i < count; ++i)
    {
        begin[i]       = Move(entries[i].raw_move);
        begin[i].value = entries[i].value;
    }
}

}  // namespace

int Search::Worker::reduction(bool i, Depth d, int mn, int delta) const {
    return zfish_search_reduction(reductions.data(), d, mn, delta, rootDelta, std::uint8_t(i));
}

TimePoint TimeManagement::optimum() const { return optimumTime; }
TimePoint TimeManagement::maximum() const { return maximumTime; }

void TimeManagement::clear() {
    availableNodes = -1;
}

void TimeManagement::advance_nodes_time(std::int64_t nodes) {
    assert(useNodesTime);
    availableNodes = std::max(int64_t(0), availableNodes - nodes);
}

void TimeManagement::init(Search::LimitsType& limits,
                          Color               us,
                          int                 ply,
                          const OptionsMap&   options,
                          double&             originalTimeAdjust) {
    const ZfishTimemanInput input = {
        .time_us              = limits.time[us],
        .inc_us               = limits.inc[us],
        .start_time           = limits.startTime,
        .npmsec               = options["nodestime"],
        .move_overhead        = options["Move Overhead"],
        .available_nodes      = availableNodes,
        .current_optimum_time = optimumTime,
        .current_maximum_time = maximumTime,
        .movestogo            = limits.movestogo,
        .ply                  = ply,
        .original_time_adjust = originalTimeAdjust,
        .ponder               = static_cast<std::uint8_t>(options["Ponder"] ? 1 : 0),
    };

    const auto output = zfish_timeman_init(input);

    startTime          = output.start_time;
    optimumTime        = output.optimum_time;
    maximumTime        = output.maximum_time;
    availableNodes     = output.available_nodes;
    useNodesTime       = output.use_nodes_time != 0;
    originalTimeAdjust = output.original_time_adjust;

    limits.time[us] = output.time_us;
    limits.inc[us]  = output.inc_us;
    limits.npmsec   = output.npmsec;
}

Value Eval::evaluate(const Eval::NNUE::Network&     network,
                     const Position&                 pos,
                     Eval::NNUE::AccumulatorStack&   accumulators,
                     Eval::NNUE::AccumulatorCaches&  caches,
                     int                             optimism) {
    assert(!pos.checkers());

    const auto [psqt, positional] = network.evaluate(pos, accumulators, caches);

    const ZfishEvalInput input = {
        .psqt                     = psqt,
        .positional               = positional,
        .optimism                 = optimism,
        .material                 = 534 * pos.count<PAWN>() + pos.non_pawn_material(),
        .rule50_count             = pos.rule50_count(),
        .value_tb_loss_in_max_ply = VALUE_TB_LOSS_IN_MAX_PLY,
        .value_tb_win_in_max_ply  = VALUE_TB_WIN_IN_MAX_PLY,
    };

    return zfish_eval_compute_value(input);
}

MovePicker::MovePicker(const Position&              p,
                       Move                         ttm,
                       Depth                        d,
                       const ButterflyHistory*      mh,
                       const LowPlyHistory*         lph,
                       const CapturePieceToHistory* cph,
                       const PieceToHistory**       ch,
                       const SharedHistories*       sh,
                       int                          pl) :
    pos(p),
    mainHistory(mh),
    lowPlyHistory(lph),
    captureHistory(cph),
    continuationHistory(ch),
    sharedHistory(sh),
    ttMove(ttm),
    depth(d),
    ply(pl) {

    if (pos.checkers())
        stage = EVASION_TT + !(ttm && pos.pseudo_legal(ttm));

    else
        stage = (depth > 0 ? MAIN_TT : QSEARCH_TT) + !(ttm && pos.pseudo_legal(ttm));
}

MovePicker::MovePicker(const Position& p, Move ttm, int th, const CapturePieceToHistory* cph) :
    pos(p),
    captureHistory(cph),
    ttMove(ttm),
    threshold(th) {
    assert(!pos.checkers());

    stage = PROBCUT_TT + !(ttm && pos.capture_stage(ttm) && pos.pseudo_legal(ttm));
}

template<GenType Type>
ExtMove* MovePicker::score(const MoveList<Type>& ml) {

    static_assert(Type == CAPTURES || Type == QUIETS || Type == EVASIONS, "Wrong type");

    Color us = pos.side_to_move();

    [[maybe_unused]] Bitboard threatByLesser[KING + 1];
    if constexpr (Type == QUIETS)
    {
        threatByLesser[PAWN]   = 0;
        threatByLesser[KNIGHT] = threatByLesser[BISHOP] = pos.attacks_by<PAWN>(~us);
        threatByLesser[ROOK] =
          pos.attacks_by<KNIGHT>(~us) | pos.attacks_by<BISHOP>(~us) | threatByLesser[KNIGHT];
        threatByLesser[QUEEN] = pos.attacks_by<ROOK>(~us) | threatByLesser[ROOK];
        threatByLesser[KING]  = 0;
    }

    ZfishMoveScoreInput inputs[MAX_MOVES]{};
    ZfishMoveSortEntry  outputs[MAX_MOVES]{};
    std::size_t         count = 0;

    for (auto move : ml)
    {
        const Square    from          = move.from_sq();
        const Square    to            = move.to_sq();
        const Piece     pc            = pos.moved_piece(move);
        const PieceType pt            = type_of(pc);
        const Piece     capturedPiece = pos.piece_on(to);

        auto& input = inputs[count++];
        input.raw_move             = move.raw();
        input.capture_history      = 0;
        input.captured_piece_value = 0;
        input.main_history         = 0;
        input.pawn_history         = 0;
        input.continuation_sum     = 0;
        input.check_bonus          = 0;
        input.from_threatened      = 0;
        input.to_threatened        = 0;
        input.capture_stage        = 0;
        input.piece_value          = 0;
        input.low_ply_bonus        = 0;

        if constexpr (Type == CAPTURES)
        {
            input.capture_history      = (*captureHistory)[pc][to][type_of(capturedPiece)];
            input.captured_piece_value = int(PieceValue[capturedPiece]);
        }
        else if constexpr (Type == QUIETS)
        {
            input.main_history     = (*mainHistory)[us][move.raw()];
            input.pawn_history     = sharedHistory->pawn_entry(pos)[pc][to];
            input.continuation_sum = (*continuationHistory[0])[pc][to]
                                     + (*continuationHistory[1])[pc][to]
                                     + (*continuationHistory[2])[pc][to]
                                     + (*continuationHistory[3])[pc][to]
                                     + (*continuationHistory[5])[pc][to];
            input.check_bonus      = (pos.check_squares(pt) & to) && pos.see_ge(move, -75);
            input.from_threatened  = bool(threatByLesser[pt] & from);
            input.to_threatened    = bool(threatByLesser[pt] & to);
            input.piece_value      = int(PieceValue[pt]);
            if (ply < LOW_PLY_HISTORY_SIZE)
                input.low_ply_bonus = 8 * (*lowPlyHistory)[ply][move.raw()] / (1 + ply);
        }
        else
        {
            input.main_history         = (*mainHistory)[us][move.raw()];
            input.continuation_sum     = (*continuationHistory[0])[pc][to];
            input.captured_piece_value = int(PieceValue[capturedPiece]);
            input.capture_stage        = pos.capture_stage(move);
        }
    }

    const std::uint8_t kind = Type == CAPTURES ? std::uint8_t{0}
                                : Type == QUIETS ? std::uint8_t{1}
                                                 : std::uint8_t{2};
    zfish_movepick_score_moves(kind, inputs, count, outputs);

    ExtMove* it = cur;
    for (std::size_t i = 0; i < count; ++i)
    {
        ExtMove& move = *it++;
        move          = Move(outputs[i].raw_move);
        move.value    = outputs[i].value;
    }
    return it;
}

template<typename Pred>
Move MovePicker::select(Pred filter) {

    for (; cur < endCur; ++cur)
        if (*cur != ttMove && filter())
            return *cur++;

    return Move::none();
}

Move MovePicker::next_move() {

    constexpr int goodQuietThreshold = -14000;
top:
    switch (stage)
    {

    case MAIN_TT :
    case EVASION_TT :
    case QSEARCH_TT :
    case PROBCUT_TT :
        ++stage;
        return ttMove;

    case CAPTURE_INIT :
    case PROBCUT_INIT :
    case QCAPTURE_INIT : {
        MoveList<CAPTURES> ml(pos);

        cur = endBadCaptures = moves;
        endCur = endCaptures = score<CAPTURES>(ml);

        partial_insertion_sort(cur, endCur, std::numeric_limits<int>::min());
        ++stage;
        goto top;
    }

    case GOOD_CAPTURE :
        if (select([&]() {
                if (pos.see_ge(*cur, -cur->value / 18))
                    return true;
                std::swap(*endBadCaptures++, *cur);
                return false;
            }))
            return *(cur - 1);

        ++stage;
        [[fallthrough]];

    case QUIET_INIT :
        if (!skipQuiets)
        {
            MoveList<QUIETS> ml(pos);

            endCur = endGenerated = score<QUIETS>(ml);

            partial_insertion_sort(cur, endCur, -3560 * depth);
        }

        ++stage;
        [[fallthrough]];

    case GOOD_QUIET :
        if (!skipQuiets && select([&]() { return cur->value > goodQuietThreshold; }))
            return *(cur - 1);

        cur    = moves;
        endCur = endBadCaptures;

        ++stage;
        [[fallthrough]];

    case BAD_CAPTURE :
        if (select([]() { return true; }))
            return *(cur - 1);

        cur    = endCaptures;
        endCur = endGenerated;

        ++stage;
        [[fallthrough]];

    case BAD_QUIET :
        if (!skipQuiets)
            return select([&]() { return cur->value <= goodQuietThreshold; });

        return Move::none();

    case EVASION_INIT : {
        MoveList<EVASIONS> ml(pos);

        cur    = moves;
        endCur = endGenerated = score<EVASIONS>(ml);

        partial_insertion_sort(cur, endCur, std::numeric_limits<int>::min());
        ++stage;
        [[fallthrough]];
    }

    case EVASION :
    case QCAPTURE :
        return select([]() { return true; });

    case PROBCUT :
        return select([&]() { return pos.see_ge(*cur, threshold); });
    }

    assert(false);
    return Move::none();
}

void MovePicker::skip_quiet_moves() { skipQuiets = true; }

static_assert(sizeof(Move) == sizeof(std::uint16_t));

extern "C" void zfish_movegen_fill_snapshot(const void* pos_ptr, ZfishMovegenSnapshot* out) {
    const auto& pos = *static_cast<const Position*>(pos_ptr);

    *out                        = {};
    out->side_to_move           = static_cast<std::uint8_t>(pos.side_to_move());
    out->pieces_all             = pos.pieces();
    out->pieces_by_color[WHITE] = pos.pieces(WHITE);
    out->pieces_by_color[BLACK] = pos.pieces(BLACK);
    out->pieces_by_type[ALL_PIECES] = pos.pieces();
    out->pieces_by_type[PAWN]       = pos.pieces(PAWN);
    out->pieces_by_type[KNIGHT]     = pos.pieces(KNIGHT);
    out->pieces_by_type[BISHOP]     = pos.pieces(BISHOP);
    out->pieces_by_type[ROOK]       = pos.pieces(ROOK);
    out->pieces_by_type[QUEEN]      = pos.pieces(QUEEN);
    out->pieces_by_type[KING]       = pos.pieces(KING);
    out->king_square[WHITE]         = static_cast<std::uint8_t>(pos.square<KING>(WHITE));
    out->king_square[BLACK]         = static_cast<std::uint8_t>(pos.square<KING>(BLACK));
    out->ep_square                  = static_cast<std::uint8_t>(pos.ep_square());
    out->checkers                   = pos.checkers();
    out->blockers_for_king[WHITE]   = pos.blockers_for_king(WHITE);
    out->blockers_for_king[BLACK]   = pos.blockers_for_king(BLACK);

    for (const auto cr : {WHITE_OO, WHITE_OOO, BLACK_OO, BLACK_OOO})
    {
        if (pos.can_castle(cr))
            out->castling_rights |= static_cast<std::uint8_t>(cr);
        out->castling_impeded[cr]    = static_cast<std::uint8_t>(pos.castling_impeded(cr));
        out->castling_rook_square[cr] = static_cast<std::uint8_t>(pos.castling_rook_square(cr));
    }
}

extern "C" std::uint64_t zfish_movegen_attacks(std::uint8_t piece_type,
                                                std::uint8_t square,
                                                std::uint64_t occupied) {
    return attacks_bb(static_cast<PieceType>(piece_type), static_cast<Square>(square), occupied);
}

extern "C" std::uint64_t zfish_movegen_between(std::uint8_t from, std::uint8_t to) {
    return between_bb(static_cast<Square>(from), static_cast<Square>(to));
}

template<>
Move* generate<CAPTURES>(const Position& pos, Move* moveList) {
    const auto count = zfish_movegen_generate_captures(&pos, reinterpret_cast<std::uint16_t*>(moveList));
    return moveList + count;
}

template<>
Move* generate<QUIETS>(const Position& pos, Move* moveList) {
    const auto count = zfish_movegen_generate_quiets(&pos, reinterpret_cast<std::uint16_t*>(moveList));
    return moveList + count;
}

template<>
Move* generate<EVASIONS>(const Position& pos, Move* moveList) {
    const auto count = zfish_movegen_generate_evasions(&pos, reinterpret_cast<std::uint16_t*>(moveList));
    return moveList + count;
}

template<>
Move* generate<NON_EVASIONS>(const Position& pos, Move* moveList) {
    const auto count =
      zfish_movegen_generate_non_evasions(&pos, reinterpret_cast<std::uint16_t*>(moveList));
    return moveList + count;
}

template<>
Move* generate<LEGAL>(const Position& pos, Move* moveList) {

    Color    us     = pos.side_to_move();
    Bitboard pinned = pos.blockers_for_king(us) & pos.pieces(us);
    Square   ksq    = pos.square<KING>(us);
    Move*    cur    = moveList;

    moveList = pos.checkers() ? generate<EVASIONS>(pos, moveList) : generate<NON_EVASIONS>(pos, moveList);
    while (cur != moveList)
        if (((pinned & cur->from_sq()) || cur->from_sq() == ksq || cur->type_of() == EN_PASSANT)
            && !pos.legal(*cur))
            *cur = *(--moveList);
        else
            ++cur;

    return moveList;
}

static constexpr int ClusterSize = 3;

struct TTEntry {
    TTData read() const {
        const auto output = zfish_tt_entry_read(reinterpret_cast<const ZfishTtEntry*>(this), DEPTH_NONE);
        return TTData{Move(output.move16), Value(output.value16), Value(output.eval16),
                      Depth(output.depth), Bound(output.bound), output.is_pv != 0};
    }

    bool is_occupied() const { return bool(depth8); }
    void save(Key k, Value v, bool pv, Bound b, Depth d, Move m, Value ev, std::uint8_t curr_generation);
    std::uint8_t relative_age(std::uint8_t curr_generation) const;

  private:
    friend class TranspositionTable;

    std::uint16_t key16;
    std::uint8_t  depth8;
    std::uint8_t  gen_bound8;
    std::uint16_t move16;
    std::int16_t  value16;
    std::int16_t  eval16;
};

void TTEntry::save(
  Key k, Value v, bool pv, Bound b, Depth d, Move m, Value ev, std::uint8_t curr_generation) {
    zfish_tt_entry_save(reinterpret_cast<ZfishTtEntry*>(this), k, v,
                        static_cast<std::uint8_t>(pv ? 1 : 0), static_cast<std::uint8_t>(b), d,
                        DEPTH_NONE, m.raw(), ev, curr_generation);
}

std::uint8_t TTEntry::relative_age(std::uint8_t curr_generation) const {
    return zfish_tt_entry_relative_age(reinterpret_cast<const ZfishTtEntry*>(this), curr_generation);
}

TTWriter::TTWriter(TTEntry* tte) :
    entry(tte) {}

void TTWriter::write(
  Key k, Value v, bool pv, Bound b, Depth d, Move m, Value ev, std::uint8_t curr_generation) {
    entry->save(k, v, pv, b, d, m, ev, curr_generation);
}

struct Cluster {
    TTEntry entry[ClusterSize];
    char    padding[2];
};

static_assert(sizeof(Cluster) == 32, "Suboptimal Cluster size");

void TranspositionTable::resize(size_t mbSize, ThreadPool& threads) {
    aligned_large_pages_free(table);

    clusterCount = mbSize * 1024 * 1024 / sizeof(Cluster);

    table = static_cast<Cluster*>(aligned_large_pages_alloc(clusterCount * sizeof(Cluster)));

    if (!table)
    {
        std::cerr << "Failed to allocate " << mbSize << "MB for transposition table." << std::endl;
        exit(EXIT_FAILURE);
    }

    clear(threads);
}

void TranspositionTable::clear(ThreadPool& threads) {
    generation8              = 0;
    const size_t threadCount = threads.num_threads();

    for (size_t i = 0; i < threadCount; ++i)
    {
        threads.run_on_thread(i, [this, i, threadCount]() {
            const size_t stride = clusterCount / threadCount;
            const size_t start  = stride * i;
            const size_t len    = i + 1 != threadCount ? stride : clusterCount - start;

            std::memset(&table[start], 0, len * sizeof(Cluster));
        });
    }

    for (size_t i = 0; i < threadCount; ++i)
        threads.wait_on_thread(i);
}

int TranspositionTable::hashfull(int maxAge) const {
    return zfish_tt_hashfull(reinterpret_cast<const ZfishTtCluster*>(table), clusterCount,
                             generation8, maxAge);
}

void TranspositionTable::new_search() { generation8 = zfish_tt_generation_next(generation8); }

std::uint8_t TranspositionTable::generation() const { return generation8; }

std::tuple<bool, TTData, TTWriter> TranspositionTable::probe(const Key key) const {
    TTEntry* const tte = first_entry(key);

    const auto output = zfish_tt_probe(reinterpret_cast<const ZfishTtCluster*>(
                                         reinterpret_cast<const Cluster*>(tte)),
                                       key, generation8, DEPTH_NONE);

    if (output.found != 0)
    {
        const auto& data = output.data;
        return {true,
                TTData{Move(data.move16), Value(data.value16), Value(data.eval16), Depth(data.depth),
                       Bound(data.bound), data.is_pv != 0},
                TTWriter(&tte[output.writer_index])};
    }

    return {false, TTData{Move::none(), VALUE_NONE, VALUE_NONE, DEPTH_NONE, BOUND_NONE, false},
            TTWriter(&tte[output.writer_index])};
}

TTEntry* TranspositionTable::first_entry(const Key key) const {
    const auto cluster_index = zfish_tt_first_entry_index(key, clusterCount);
    return &table[cluster_index].entry[0];
}

Thread::Thread(Search::SharedState&                    sharedState,
               std::unique_ptr<Search::ISearchManager> sm,
               size_t                                  n,
               size_t                                  numaN,
               size_t                                  totalNumaCount,
               OptionalThreadToNumaNodeBinder          binder) :
    idx(n),
    idxInNuma(numaN),
    totalNuma(totalNumaCount),
    nthreads(sharedState.options["Threads"]),
    stdThread(&Thread::idle_loop, this) {

    wait_for_search_finished();

    run_custom_job([this, &binder, &sharedState, &sm, n]() {
        this->numaAccessToken = binder();
        this->worker          = make_unique_large_page<Search::Worker>(
          sharedState, std::move(sm), n, idxInNuma, totalNuma, this->numaAccessToken);
    });

    wait_for_search_finished();
}

Thread::~Thread() {

    assert(!searching);

    exit = true;
    start_searching();
    stdThread.join();
}

void Thread::start_searching() {
    assert(worker != nullptr);
    run_custom_job([this]() { worker->start_searching(); });
}

void Thread::clear_worker() {
    assert(worker != nullptr);
    run_custom_job([this]() { worker->clear(); });
}

void Thread::wait_for_search_finished() {

    std::unique_lock<std::mutex> lk(mutex);
    cv.wait(lk, [&] { return !searching; });
}

void Thread::run_custom_job(std::function<void()> f) {
    {
        std::unique_lock<std::mutex> lk(mutex);
        cv.wait(lk, [&] { return !searching; });
        jobFunc   = std::move(f);
        searching = true;
    }
    cv.notify_one();
}

void Thread::ensure_network_replicated() { worker->ensure_network_replicated(); }

void Thread::idle_loop() {
    while (true)
    {
        std::unique_lock<std::mutex> lk(mutex);
        searching = false;
        cv.notify_one();
        cv.wait(lk, [&] { return searching; });

        if (exit)
            return;

        std::function<void()> job = std::move(jobFunc);
        jobFunc                   = nullptr;

        lk.unlock();

        if (job)
            job();
    }
}

Search::SearchManager* ThreadPool::main_manager() { return main_thread()->worker->main_manager(); }

uint64_t ThreadPool::nodes_searched() const { return accumulate(&Search::Worker::nodes); }
uint64_t ThreadPool::tb_hits() const { return accumulate(&Search::Worker::tbHits); }

static size_t next_power_of_two(uint64_t count) {
    return zfish_thread_next_power_of_two(count);
}

void ThreadPool::set(const NumaConfig&                           numaConfig,
                     Search::SharedState                         sharedState,
                     const Search::SearchManager::UpdateContext& updateContext) {

    if (threads.size() > 0)
    {
        main_thread()->wait_for_search_finished();

        threads.clear();

        boundThreadToNumaNode.clear();
    }

    const size_t requested = sharedState.options["Threads"];

    if (requested > 0)
    {
        const std::string numaPolicy(sharedState.options["NumaPolicy"]);
        const bool        doBindThreads = [&]() {
            if (numaPolicy == "none")
                return false;

            if (numaPolicy == "auto")
                return numaConfig.suggests_binding_threads(requested);

            return true;
        }();

        std::map<NumaIndex, size_t> counts;
        boundThreadToNumaNode = doBindThreads
                                  ? numaConfig.distribute_threads_among_numa_nodes(requested)
                                  : std::vector<NumaIndex>{};

        if (boundThreadToNumaNode.empty())
            counts[0] = requested;
        else
        {
            for (size_t i = 0; i < boundThreadToNumaNode.size(); ++i)
                counts[boundThreadToNumaNode[i]]++;
        }

        sharedState.sharedHistories.clear();
        for (auto pair : counts)
        {
            NumaIndex numaIndex = pair.first;
            uint64_t  count     = pair.second;
            auto      f         = [&]() {
                sharedState.sharedHistories.try_emplace(numaIndex, next_power_of_two(count));
            };
            if (doBindThreads)
                numaConfig.execute_on_numa_node(numaIndex, f);
            else
                f();
        }

        auto threadsPerNode = counts;
        counts.clear();

        while (threads.size() < requested)
        {
            const size_t    threadId      = threads.size();
            const NumaIndex numaId        = doBindThreads ? boundThreadToNumaNode[threadId] : 0;
            auto            create_thread = [&]() {
                auto manager = threadId == 0
                                 ? std::unique_ptr<Search::ISearchManager>(
                                     std::make_unique<Search::SearchManager>(updateContext))
                                 : std::make_unique<Search::NullSearchManager>();

                auto binder = doBindThreads ? OptionalThreadToNumaNodeBinder(numaConfig, numaId)
                                            : OptionalThreadToNumaNodeBinder(numaId);

                threads.emplace_back(std::make_unique<Thread>(sharedState, std::move(manager),
                                                              threadId, counts[numaId]++,
                                                              threadsPerNode[numaId], binder));
            };

            if (doBindThreads)
                numaConfig.execute_on_numa_node(numaId, create_thread);
            else
                create_thread();
        }

        clear();

        main_thread()->wait_for_search_finished();
    }
}

void ThreadPool::clear() {
    if (threads.size() == 0)
        return;

    for (auto&& th : threads)
        th->clear_worker();

    for (auto&& th : threads)
        th->wait_for_search_finished();

    main_manager()->bestPreviousAverageScore = VALUE_INFINITE;
    main_manager()->previousTimeReduction    = 0.85;

    main_manager()->callsCnt           = 0;
    main_manager()->bestPreviousScore  = VALUE_INFINITE;
    main_manager()->originalTimeAdjust = -1;
    main_manager()->tm.clear();
}

void ThreadPool::run_on_thread(size_t threadId, std::function<void()> f) {
    assert(threads.size() > threadId);
    threads[threadId]->run_custom_job(std::move(f));
}

void ThreadPool::wait_on_thread(size_t threadId) {
    assert(threads.size() > threadId);
    threads[threadId]->wait_for_search_finished();
}

size_t ThreadPool::num_threads() const { return threads.size(); }

void ThreadPool::start_thinking(const OptionsMap&  options,
                                Position&          pos,
                                StateListPtr&      states,
                                Search::LimitsType limits) {

    main_thread()->wait_for_search_finished();

    main_manager()->stopOnPonderhit = stop = false;
    main_manager()->ponder          = limits.ponderMode;

    increaseDepth = true;

    Search::RootMoves rootMoves;
    const auto        legalmoves = MoveList<LEGAL>(pos);

    for (const auto& uciMove : limits.searchmoves)
    {
        auto move = UCIEngine::to_move(pos, uciMove);

        if (std::find(legalmoves.begin(), legalmoves.end(), move) != legalmoves.end())
            rootMoves.emplace_back(move);
    }

    if (rootMoves.empty())
        for (const auto& m : legalmoves)
            rootMoves.emplace_back(m);

    Tablebases::Config tbConfig = Tablebases::rank_root_moves(options, pos, rootMoves);

    assert(states.get() || setupStates.get());

    if (states.get())
        setupStates = std::move(states);

    for (auto&& th : threads)
    {
        th->run_custom_job([&]() {
            th->worker->limits           = limits;
            th->worker->nodes            = 0;
            th->worker->tbHits           = 0;
            th->worker->bestMoveChanges  = 0;
            th->worker->nmpMinPly        = 0;
            th->worker->rootDepth        = 0;
            th->worker->rootMoves        = rootMoves;
            th->worker->rootPos.set(pos.fen(), pos.is_chess960(), &th->worker->rootState);
            th->worker->rootState = setupStates->back();
            th->worker->tbConfig  = tbConfig;
        });
    }

    for (auto&& th : threads)
        th->wait_for_search_finished();

    main_thread()->start_searching();
}

Thread* ThreadPool::get_best_thread() const {

    ZfishThreadSummary summaries[1024]{};
    const auto count = threads.size();

    for (std::size_t i = 0; i < count; ++i)
    {
        const auto& rootMove             = threads[i]->worker->rootMoves[0];
        summaries[i].pv0_raw             = rootMove.pv[0].raw();
        summaries[i].score_is_bound      = rootMove.score_is_bound();
        summaries[i].pv_has_more_than_two = rootMove.pv.size() > 2;
        summaries[i].score               = rootMove.score;
        summaries[i].root_depth          = int(threads[i]->worker->rootDepth);
    }

    return threads[zfish_thread_pick_best_thread(summaries, count)].get();
}

void ThreadPool::start_searching() {

    for (auto&& th : threads)
        if (th != threads.front())
            th->start_searching();
}

void ThreadPool::wait_for_search_finished() const {

    for (auto&& th : threads)
        if (th != threads.front())
            th->wait_for_search_finished();
}

std::vector<size_t> ThreadPool::get_bound_thread_count_by_numa_node() const {
    std::vector<size_t> counts;

    if (!boundThreadToNumaNode.empty())
    {
        NumaIndex highestNumaNode = 0;
        for (NumaIndex n : boundThreadToNumaNode)
            if (n > highestNumaNode)
                highestNumaNode = n;

        counts.resize(highestNumaNode + 1, 0);

        for (NumaIndex n : boundThreadToNumaNode)
            counts[n] += 1;
    }

    return counts;
}

void ThreadPool::ensure_network_replicated() {
    for (auto&& th : threads)
        th->ensure_network_replicated();
}

}  // namespace Stockfish

namespace Stockfish {

std::string build_nnue_trace(Stockfish::Position&                     pos,
                             const Stockfish::Eval::NNUE::Network&     network,
                             Stockfish::Eval::NNUE::AccumulatorCaches& caches);

#include "uci_bridge/misc_text.inc"

#include "uci_bridge/engine_numa_text.inc"

#include "uci_bridge/engine_view_helpers.inc"

#include "uci_bridge/engine_network_helpers.inc"

#include "uci_bridge/engine_trace_eval.inc"

#include "uci_bridge/engine_runtime_controls.inc"

#include "uci_bridge/eval_trace_entry.inc"

#include "uci_bridge/nnue_trace_builder.inc"

#include "uci_bridge/debug_state.inc"

#include "uci_bridge/debug_hit.inc"

#include "uci_bridge/debug_mean.inc"

#include "uci_bridge/debug_stdev.inc"

#include "uci_bridge/debug_extremes.inc"

#include "uci_bridge/debug_correl.inc"

#include "uci_bridge/debug_print.inc"

#include "uci_bridge/debug_clear.inc"

#include "uci_bridge/take_string_and_free_required_uci.inc"

#include "uci_bridge/start_logger.inc"

#include "uci_bridge/sync_cout_operator.inc"

#include "uci_bridge/sync_cout_helpers.inc"

std::uint64_t Engine::perft(const std::string& fen, Depth depth, bool isChess960) {
    verify_network();

    return Benchmark::perft(fen, depth, isChess960);
}

#include "uci_bridge/engine_go.inc"

#include "uci_bridge/engine_stop_and_clear.inc"

#include "uci_bridge/engine_listener_helpers.inc"

#include "uci_bridge/engine_set_position.inc"

Engine::Engine(std::optional<std::string> path) :
        binaryDirectory(path ? CommandLine::get_binary_directory(*path) : ""),
        numaContext(NumaConfig::from_system(DefaultNumaPolicy)),
        states(new std::deque<StateInfo>(1)),
        threads(),
        network(numaContext, get_default_network()) {

        pos.set(StartFEN, false, &states->back());

        options.add(
            "Debug Log File", Option("", [](const Option& o) {
                    start_logger(o);
                    return std::nullopt;
            }));

        options.add(
            "NumaPolicy", Option("auto", [this](const Option& o) {
                    set_numa_config_from_option(o);
                    return numa_config_information_as_string() + "\n"
                             + thread_allocation_information_as_string();
            }));

        options.add(
            "Threads", Option(1, 1, MaxThreads, [this](const Option&) {
                    resize_threads();
                    return thread_allocation_information_as_string();
            }));

        options.add(
            "Hash", Option(16, 1, MaxHashMB, [this](const Option& o) {
                    set_tt_size(o);
                    return std::nullopt;
            }));

        options.add(
            "Clear Hash", Option([this](const Option&) {
                    search_clear();
                    return std::nullopt;
            }));

        options.add("Ponder", Option(false));
        options.add("MultiPV", Option(1, 1, MAX_MOVES));
        options.add("Skill Level", Option(20, 0, 20));
        options.add("Move Overhead", Option(10, 0, 5000));
        options.add("nodestime", Option(0, 0, 10000));
        options.add("UCI_Chess960", Option(false));
        options.add("UCI_LimitStrength", Option(false));
        options.add("UCI_Elo",
                                Option(Stockfish::Search::Skill::LowestElo, Stockfish::Search::Skill::LowestElo,
                                             Stockfish::Search::Skill::HighestElo));
        options.add("UCI_ShowWDL", Option(false));

        options.add(
            "SyzygyPath", Option("", [](const Option& o) {
                    Tablebases::init(o);
                    return std::nullopt;
            }));

        options.add("SyzygyProbeDepth", Option(1, 1, 100));
        options.add("Syzygy50MoveRule", Option(true));
        options.add("SyzygyProbeLimit", Option(7, 0, 7));

        options.add(
            "EvalFile", Option(EvalFileDefaultName, [this](const Option& o) {
                    load_network(o);
                    return std::nullopt;
            }));

        threads.clear();
        threads.ensure_network_replicated();
        resize_threads();
}

constexpr auto BenchmarkCommand = "speedtest";

extern "C" {
struct ZfishParsedLimits {
    std::int64_t wtime;
    std::int64_t btime;
    std::int64_t winc;
    std::int64_t binc;
    int          movestogo;
    int          depth;
    int          mate;
    int          perft;
    int          infinite;
    std::int64_t movetime;
    std::uint64_t nodes;
    std::uint8_t  ponder_mode;
    const char*   searchmoves;
};

struct ZfishParsedPosition {
    std::uint8_t ok;
    const char*  fen;
    const char*  moves;
};

struct ZfishBenchmarkSetupOutput {
    int         tt_size;
    int         threads;
    const char* commands_ptr;
    const char* original_invocation_ptr;
    const char* filled_invocation_ptr;
};

const char*   zfish_position_build_endgame_fen(const unsigned char* code_ptr,
                                               std::size_t          code_len,
                                               std::uint8_t         color);
const char*   zfish_position_format_fen(const unsigned char* board_ptr,
                                        std::uint8_t         side_to_move,
                                        std::uint8_t         chess960,
                                        std::uint8_t         castling_rights,
                                        std::uint8_t         white_oo_rook_square,
                                        std::uint8_t         white_ooo_rook_square,
                                        std::uint8_t         black_oo_rook_square,
                                        std::uint8_t         black_ooo_rook_square,
                                        std::uint8_t         ep_square,
                                        int                  rule50,
                                        int                  game_ply);
std::uint64_t zfish_position_compute_material_key(const int* piece_counts_ptr,
                                                  std::size_t piece_count_len);
void          zfish_position_init_runtime();
const char*   zfish_bitboard_pretty(Stockfish::Bitboard bitboard);
void          zfish_bitboards_init();
}

namespace {

#include "uci_bridge/string_free_helpers.inc"

}  // namespace

uint8_t PopCnt16[1 << 16];
uint8_t SquareDistance[SQUARE_NB][SQUARE_NB];

Bitboard LineBB[SQUARE_NB][SQUARE_NB];
Bitboard BetweenBB[SQUARE_NB][SQUARE_NB];
Bitboard RayPassBB[SQUARE_NB][SQUARE_NB];

alignas(64) Magic Magics[SQUARE_NB][2];

namespace {

using MagicMask = Bitboard;

[[maybe_unused]] constexpr Bitboard constexpr_pext(Bitboard b, Bitboard m) {
    Bitboard result = 0, bit = 0;
    while (m)
    {
        Bitboard last = m & -m;
        result |= bool(b & last) << bit++;
        m ^= last;
    }
    return result;
}

void init_magics(PieceType pt, MagicMask table[], Magic magics[][2], [[maybe_unused]] bool tableAlreadyInit) {
    tableAlreadyInit = false;

    int seeds[][RANK_NB] = {{8977, 44560, 54343, 38998, 5731, 95205, 104912, 17020},
                            {728, 10316, 55013, 32803, 12281, 15100, 16645, 255}};

    Bitboard occupancy[4096];
    int      epoch[4096] = {}, cnt = 0;
    Bitboard reference[4096] = {};
    int      size = 0;

    for (Square s = SQ_A1; s <= SQ_H8; ++s)
    {
        Bitboard edges = ((Rank1BB | Rank8BB) & ~rank_bb(s)) | ((FileABB | FileHBB) & ~file_bb(s));

        Magic&   m       = magics[s][pt - BISHOP];
        Bitboard attacks = Bitboards::sliding_attack(pt, s, 0);
        m.mask           = attacks & ~edges;
        m.shift          = (Is64Bit ? 64 : 32) - popcount(m.mask);

        m.attacks = s == SQ_A1 ? table : magics[s - 1][pt - BISHOP].attacks + size;
        size      = 0;

        Bitboard b = 0;
        do
        {
            occupancy[size] = b;
            reference[size] = Bitboards::sliding_attack(pt, s, b);

            size++;
            b = (b - m.mask) & m.mask;
        } while (b);

        PRNG rng(seeds[Is64Bit][rank_of(s)]);

        for (int i = 0; i < size;)
        {
            for (m.magic = 0; popcount((m.magic * m.mask) >> 56) < 6;)
                m.magic = rng.sparse_rand<Bitboard>();

            for (++cnt, i = 0; i < size; ++i)
            {
                unsigned idx = m.index(occupancy[i]);

                if (epoch[idx] < cnt)
                {
                    epoch[idx]     = cnt;
                    m.attacks[idx] = reference[i];
                }
                else if (m.attacks[idx] != reference[i])
                    break;
            }
        }
    }
}

std::array<Bitboard, 0x19000> RookTable;
std::array<Bitboard, 0x1480>  BishopTable;

}  // namespace

extern "C" {

#include "uci_bridge/position_runtime_exports.inc"

}

namespace Bitboards {

void init() {
    for (unsigned i = 0; i < (1 << 16); ++i)
        PopCnt16[i] = uint8_t(std::bitset<16>(i).count());

    for (Square s1 = SQ_A1; s1 <= SQ_H8; ++s1)
        for (Square s2 = SQ_A1; s2 <= SQ_H8; ++s2)
            SquareDistance[s1][s2] = std::max(distance<File>(s1, s2), distance<Rank>(s1, s2));

    init_magics(ROOK, const_cast<MagicMask*>(RookTable.data()), Magics, true);
    init_magics(BISHOP, const_cast<MagicMask*>(BishopTable.data()), Magics, true);

    for (Square s1 = SQ_A1; s1 <= SQ_H8; ++s1)
    {
        for (PieceType pt : {BISHOP, ROOK})
            for (Square s2 = SQ_A1; s2 <= SQ_H8; ++s2)
            {
                if (PseudoAttacks[pt][s1] & s2)
                {
                    LineBB[s1][s2] = (attacks_bb(pt, s1, 0) & attacks_bb(pt, s2, 0)) | s1 | s2;
                    BetweenBB[s1][s2] =
                      (attacks_bb(pt, s1, square_bb(s2)) & attacks_bb(pt, s2, square_bb(s1)));
                    RayPassBB[s1][s2] =
                      attacks_bb(pt, s1, 0) & (attacks_bb(pt, s2, square_bb(s1)) | s2);
                }
                BetweenBB[s1][s2] |= s2;
            }
    }
}

#include "uci_bridge/bitboard_pretty.inc"

}  // namespace Bitboards

#include "uci_bridge/position_format_helpers.inc"

UCIEngine::UCIEngine(int argc, char** argv) :
    engine(argv[0]),
    cli(argc, argv) {

    engine.get_options().add_info_listener([](const std::optional<std::string>& str) {
        if (str.has_value())
            print_info_string(*str);
    });

    init_search_update_listeners();
}

void UCIEngine::init_search_update_listeners() {
    engine.set_on_iter([](const auto& i) { on_iter(i); });
    engine.set_on_update_no_moves([](const auto& i) { on_update_no_moves(i); });
    engine.set_on_update_full(
      [this](const auto& i) { on_update_full(i, engine.get_options()["UCI_ShowWDL"]); });
    engine.set_on_bestmove([](const auto& bm, const auto& p) { on_bestmove(bm, p); });
    engine.set_on_verify_network([](const auto& s) { print_info_string(s); });
}

void UCIEngine::loop() {
    std::string token, cmd;

    for (int i = 1; i < cli.argc; ++i)
        cmd += std::string(cli.argv[i]) + " ";

    do
    {
        if (cli.argc == 1 && !getline(std::cin, cmd))
            cmd = "quit";

        std::istringstream is(cmd);

        token.clear();
        is >> token;

        if (token == "quit" || token == "stop")
            engine.stop();
        else if (token == "ponderhit")
            engine.set_ponderhit(false);
        else if (token == "uci")
        {
            sync_cout << "id name " << engine_info(true) << "\n" << engine.get_options() << sync_endl;
            sync_cout << "uciok" << sync_endl;
        }
        else if (token == "setoption")
            setoption(is);
        else if (token == "go")
        {
            print_info_string(engine.numa_config_information_as_string());
            print_info_string(engine.thread_allocation_information_as_string());
            go(is);
        }
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
            engine.search_clear();
        else if (token == "isready")
            sync_cout << "readyok" << sync_endl;
        else if (token == "flip")
            engine.flip();
        else if (token == "bench")
            bench(is);
        else if (token == BenchmarkCommand)
            benchmark(is);
        else if (token == "d")
            sync_cout << engine.visualize() << sync_endl;
        else if (token == "eval")
            engine.trace_eval();
        else if (token == "compiler")
            sync_cout << compiler_info() << sync_endl;
        else if (token == "export_net")
        {
            std::pair<std::optional<std::string>, std::string> file;

            if (is >> file.second)
                file.first = file.second;

            engine.save_network(file);
        }
        else if (token == "--help" || token == "help" || token == "--license"
                 || token == "license")
            sync_cout << help_text() << sync_endl;
        else if (!token.empty() && token[0] != '#')
            sync_cout << format_unknown_command(cmd) << sync_endl;

    } while (token != "quit" && cli.argc == 1);
}

void UCIEngine::go(std::istringstream& is) {

    Search::LimitsType limits = parse_limits(is);

    if (limits.perft)
        perft(limits);
    else
        engine.go(limits);
}

void UCIEngine::bench(std::istream& args) {
    std::string token;
    uint64_t    num, nodes = 0, cnt = 1;
    uint64_t    nodesSearched = 0;
    const auto& options       = engine.get_options();

    engine.set_on_update_full([&](const auto& i) {
        nodesSearched = i.nodes;
        on_update_full(i, options["UCI_ShowWDL"]);
    });

    std::vector<std::string> list = Benchmark::setup_bench(engine.fen(), args);

    num = count_if(list.begin(), list.end(),
                   [](const std::string& s) { return s.find("go ") == 0 || s.find("eval") == 0; });

    TimePoint elapsed = now();

    for (const auto& cmd : list)
    {
        std::istringstream is(cmd);
        is >> token;

        if (token == "go" || token == "eval")
        {
            std::cerr << "\nPosition: " << cnt++ << '/' << num << " (" << engine.fen() << ")"
                      << std::endl;
            if (token == "go")
            {
                Search::LimitsType limits = parse_limits(is);

                if (limits.perft)
                    nodesSearched = perft(limits);
                else
                {
                    engine.go(limits);
                    engine.wait_for_search_finished();
                }

                nodes += nodesSearched;
                nodesSearched = 0;
            }
            else
                engine.trace_eval();
        }
        else if (token == "setoption")
            setoption(is);
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
        {
            engine.search_clear();
            elapsed = now();
        }
    }

    elapsed = now() - elapsed + 1;

    dbg_print();

    std::cerr << "\n==========================="
              << "\nTotal time (ms) : " << elapsed
              << "\nNodes searched  : " << nodes
              << "\nNodes/second    : " << 1000 * nodes / elapsed << std::endl;

    engine.set_on_update_full([&](const auto& i) { on_update_full(i, options["UCI_ShowWDL"]); });
}

void UCIEngine::benchmark(std::istream& args) {
    static constexpr int NUM_WARMUP_POSITIONS = 3;

    std::string token;
    uint64_t    nodes = 0, cnt = 1;
    uint64_t    nodesSearched = 0;

    engine.set_on_update_full([&](const Engine::InfoFull& i) { nodesSearched = i.nodes; });

    engine.set_on_iter([](const auto&) {});
    engine.set_on_update_no_moves([](const auto&) {});
    engine.set_on_bestmove([](const auto&, const auto&) {});
    engine.set_on_verify_network([](const auto&) {});

    Benchmark::BenchmarkSetup setup = Benchmark::setup_benchmark(args);

    const auto numGoCommands = count_if(setup.commands.begin(), setup.commands.end(),
                                        [](const std::string& s) { return s.find("go ") == 0; });

    TimePoint totalTime = 0;

    auto ss = std::istringstream("name Threads value " + std::to_string(setup.threads));
    setoption(ss);
    ss = std::istringstream("name Hash value " + std::to_string(setup.ttSize));
    setoption(ss);
    ss = std::istringstream("name UCI_Chess960 value false");
    setoption(ss);

    for (const auto& cmd : setup.commands)
    {
        std::istringstream is(cmd);
        is >> token;

        if (token == "go")
        {
            std::cerr << "\rWarmup position " << cnt++ << '/' << NUM_WARMUP_POSITIONS;

            Search::LimitsType limits = parse_limits(is);
            engine.go(limits);
            engine.wait_for_search_finished();
        }
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
        {
            engine.search_clear();
        }

        if (cnt > NUM_WARMUP_POSITIONS)
            break;
    }

    std::cerr << "\n";

    cnt   = 1;
    nodes = 0;

    int           numHashfullReadings = 0;
    constexpr int hashfullAges[]      = {0, 999};
    constexpr int hashfullAgeCount    = std::size(hashfullAges);
    int           totalHashfull[hashfullAgeCount] = {0};
    int           maxHashfull[hashfullAgeCount]   = {0};

    auto updateHashfullReadings = [&]() {
        numHashfullReadings += 1;

        for (int i = 0; i < hashfullAgeCount; ++i)
        {
            const int hashfull = engine.get_hashfull(hashfullAges[i]);
            maxHashfull[i]     = std::max(maxHashfull[i], hashfull);
            totalHashfull[i] += hashfull;
        }
    };

    engine.search_clear();

    for (const auto& cmd : setup.commands)
    {
        std::istringstream is(cmd);
        is >> token;

        if (token == "go")
        {
            std::cerr << "\rPosition " << cnt++ << '/' << numGoCommands;

            Search::LimitsType limits = parse_limits(is);

            nodesSearched     = 0;
            TimePoint elapsed = now();

            engine.go(limits);
            engine.wait_for_search_finished();

            totalTime += now() - elapsed;

            updateHashfullReadings();

            nodes += nodesSearched;
        }
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
        {
            engine.search_clear();
        }
    }

    totalTime = std::max<TimePoint>(totalTime, 1);

    dbg_print();

    std::cerr << "\n";

    static_assert(
      std::size(hashfullAges) == 2 && hashfullAges[0] == 0 && hashfullAges[1] == 999,
      "Hardcoded for display. Would complicate the code needlessly in the current state.");

    std::string threadBinding = engine.thread_binding_information_as_string();
    if (threadBinding.empty())
        threadBinding = "none";

    std::cerr << "==========================="
              << "\nVersion                    : "
              << engine_version_info() << compiler_info()
              << "Large pages                : " << (has_large_pages() ? "yes" : "no")
              << "\nUser invocation            : " << BenchmarkCommand << " "
              << setup.originalInvocation << "\nFilled invocation          : " << BenchmarkCommand
              << " " << setup.filledInvocation
              << "\nAvailable processors       : " << engine.get_numa_config_as_string()
              << "\nThread count               : " << setup.threads
              << "\nThread binding             : " << threadBinding
              << "\nTT size [MiB]              : " << setup.ttSize
              << "\nHash max, avg [per mille]  : "
              << "\n    single search          : " << maxHashfull[0] << ", "
              << totalHashfull[0] / numHashfullReadings
              << "\n    single game            : " << maxHashfull[1] << ", "
              << totalHashfull[1] / numHashfullReadings
              << "\nTotal nodes searched       : " << nodes
              << "\nTotal search time [s]      : " << totalTime / 1000.0
              << "\nNodes/second               : " << 1000 * nodes / totalTime << std::endl;

    init_search_update_listeners();
}

void UCIEngine::setoption(std::istringstream& is) {
    engine.wait_for_search_finished();
    engine.get_options().setoption(is);
}

std::uint64_t UCIEngine::perft(const Search::LimitsType& limits) {
    auto nodes = engine.perft(engine.fen(), limits.perft, engine.get_options()["UCI_Chess960"]);
    sync_cout << "\nNodes searched: " << nodes << "\n" << sync_endl;
    return nodes;
}

Move UCIEngine::to_move(const Position& pos, std::string str) {
    str = to_lower(str);

    for (const auto& m : MoveList<LEGAL>(pos))
        if (str == move(m, pos.is_chess960()))
            return m;

    return Move::none();
}

bool Tune::update_on_last;
OptionsMap* Tune::options;

void OptionsMap::add_info_listener(InfoListener&& message_func) {
    info = std::move(message_func);
}

const Option& OptionsMap::operator[](const std::string& name) const {
    auto it = options_map.find(name);
    assert(it != options_map.end());
    return it->second;
}

void OptionsMap::add(const std::string& name, const Option& option) {
    if (!options_map.count(name))
    {
        static size_t insert_order = 0;

        options_map[name] = option;

        options_map[name].parent = this;
        options_map[name].idx    = insert_order++;
    }
    else
    {
        std::cerr << "Option \"" << name << "\" was already added!" << std::endl;
        std::exit(EXIT_FAILURE);
    }
}

std::size_t OptionsMap::count(const std::string& name) const { return options_map.count(name); }

Option::Option(const OptionsMap* map) :
    parent(map) {}

Option::Option(const char* value, OnChange onChange) :
    type("string"),
    min(0),
    max(0),
    on_change(std::move(onChange)) {
    defaultValue = currentValue = value;
}

Option::Option(bool value, OnChange onChange) :
    type("check"),
    min(0),
    max(0),
    on_change(std::move(onChange)) {
    defaultValue = currentValue = (value ? "true" : "false");
}

Option::Option(OnChange onChange) :
    type("button"),
    min(0),
    max(0),
    on_change(std::move(onChange)) {}

Option::Option(int value, int minv, int maxv, OnChange onChange) :
    type("spin"),
    min(minv),
    max(maxv),
    on_change(std::move(onChange)) {
    defaultValue = currentValue = std::to_string(value);
}

Option::Option(const char* value, const char* current, OnChange onChange) :
    type("combo"),
    min(0),
    max(0),
    on_change(std::move(onChange)) {
    defaultValue = value;
    currentValue = current;
}

Option::operator int() const {
    assert(type == "check" || type == "spin");
    return type == "spin" ? std::stoi(currentValue) : currentValue == "true";
}

Option::operator std::string() const {
    assert(type == "string");
    return currentValue;
}

bool Option::operator!=(const char* value) const { return !(*this == value); }

std::ostream& operator<<(std::ostream& os, const OptionsMap& optionsMap) {
    for (size_t idx = 0; idx < optionsMap.options_map.size(); ++idx)
        for (const auto& it : optionsMap.options_map)
            if (it.second.idx == idx)
            {
                const Option& option = it.second;
                os << "\noption name " << it.first << " type " << option.type;

                if (option.type == "check" || option.type == "combo")
                    os << " default " << option.defaultValue;
                else if (option.type == "string")
                    os << " default "
                       << (option.defaultValue.empty() ? "<empty>" : option.defaultValue);
                else if (option.type == "spin")
                    os << " default " << stoi(option.defaultValue) << " min " << option.min
                       << " max " << option.max;

                break;
            }

    return os;
}

template<>
void Tune::Entry<int>::init_option() {
    make_option(options, name, value, range);
}

template<>
void Tune::Entry<int>::read_option() {
    if (options->count(name))
        value = int((*options)[name]);
}

template<>
void Tune::Entry<Tune::PostUpdate>::init_option() {}

template<>
void Tune::Entry<Tune::PostUpdate>::read_option() {
    value();
}

void Tune::read_results() { /* ...insert your values here... */ }

}  // namespace Stockfish

extern "C" {
void* zfish_uci_create_engine(int argc, char* const* argv) {
    auto uci = std::make_unique<Stockfish::UCIEngine>(argc, const_cast<char**>(argv));
    Stockfish::Tune::init(uci->engine_options());
    return uci.release();
}

void zfish_uci_loop_engine(void* engine_ptr) {
    static_cast<Stockfish::UCIEngine*>(engine_ptr)->loop();
}

void zfish_uci_destroy_engine(void* engine_ptr) {
    delete static_cast<Stockfish::UCIEngine*>(engine_ptr);
}
}
