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

#define private public
#include "benchmark.h"
#include "search.h"
#undef private
#include "engine.h"
#include "memory.h"
#include "misc.h"
#include "movegen.h"
#include "numa.h"
#include "position.h"
#include "score.h"
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

struct ZfishEnginePositionSummary {
    std::uint8_t  side_to_move_white;
    std::uint64_t checkers;
    std::uint64_t key;
    int           material;
    int           rule50_count;
};

struct ZfishEngineTablebaseProbe {
    std::uint8_t available;
    int          wdl;
    int          wdl_state;
    int          dtz;
    int          dtz_state;
};

const char* zfish_eval_format_trace(ZfishEvalTraceInput input);
const char* zfish_nnue_format_trace(ZfishNnueTraceInput input);
const char* zfish_engine_eval_trace(void* pos, const void* network);
const char* zfish_engine_visualize(const void* pos);
void        zfish_engine_set_numa_config_from_option(void*                numa_context,
                                                     const void*          options,
                                                     void*                threads,
                                                     void*                tt,
                                                     void*                shared_hists,
                                                     void*                network,
                                                     const void*          update_context,
                                                     const unsigned char* option_ptr,
                                                     std::size_t          option_len);
void        zfish_engine_resize_threads(const void* numa_context,
                                        const void* options,
                                        void*       threads,
                                        void*       tt,
                                        void*       shared_hists,
                                        void*       network,
                                        const void* update_context);
void        zfish_engine_set_tt_size(void* threads, void* tt, std::size_t mb);
void        zfish_engine_set_ponderhit(void* threads, std::uint8_t ponder);
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
    static EvalFile& evalFile(Network& network) { return network.evalFile; }
    static const EvalFile& evalFile(const Network& network) { return network.evalFile; }

    static FeatureTransformer& featureTransformer(Network& network) {
        return network.featureTransformer;
    }

    static const FeatureTransformer& featureTransformer(const Network& network) {
        return network.featureTransformer;
    }

    static NetworkArchitecture& layer(Network& network, std::size_t bucket) {
        return network.network[bucket];
    }

    static const NetworkArchitecture& layer(const Network& network, std::size_t bucket) {
        return network.network[bucket];
    }

    static void markInitialized(Network& network) { network.initialized = true; }

    static bool isInitialized(const Network& network) { return network.initialized; }

    static std::uint32_t hashValue() { return Network::hash; }
};







namespace Detail {

template<typename T>
bool read_parameters(std::istream& stream, T& reference) {

    std::uint32_t header;
    header = read_little_endian<std::uint32_t>(stream);
    if (!stream || header != T::get_hash_value())
        return false;
    return reference.read_parameters(stream);
}

template<typename T>
bool write_parameters(std::ostream& stream, const T& reference) {

    write_little_endian<std::uint32_t>(stream, T::get_hash_value());
    return reference.write_parameters(stream);
}

}  // namespace Detail

namespace {

class NetworkBlobBuffer: public std::basic_streambuf<char> {
   public:
    NetworkBlobBuffer(const unsigned char* data, std::size_t len) {
        auto* begin = const_cast<char*>(reinterpret_cast<const char*>(data));
        setg(begin, begin, begin + len);
    }

    std::size_t consumed() const { return std::size_t(gptr() - eback()); }
};

template<typename T>
std::size_t read_parameters_blob(const unsigned char* data_ptr, std::size_t data_len, T& reference) {
    NetworkBlobBuffer buffer(data_ptr, data_len);
    std::istream      stream(&buffer);

    if (!Detail::read_parameters(stream, reference))
        return 0;

    return buffer.consumed();
}

template<typename T>
std::optional<std::string> write_parameters_blob(const T& reference) {
    std::ostringstream stream(std::ios::out | std::ios::binary);
    if (!Detail::write_parameters(stream, reference))
        return std::nullopt;

    return stream.str();
}

}  // namespace



extern "C" {
struct ZfishByteView {
    const unsigned char* ptr;
    std::size_t          len;
};

struct ZfishOwnedByteView {
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

std::size_t zfish_network_content_hash(const void* network);

ZfishByteView zfish_network_default_name(const void* network_ptr) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    return {reinterpret_cast<const unsigned char*>(NetworkBridgeAccess::evalFile(network).defaultName.data()),
            NetworkBridgeAccess::evalFile(network).defaultName.size()};
}

ZfishByteView zfish_network_current_name(const void* network_ptr) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    return {reinterpret_cast<const unsigned char*>(NetworkBridgeAccess::evalFile(network).current.data()),
            NetworkBridgeAccess::evalFile(network).current.size()};
}

ZfishByteView zfish_network_description(const void* network_ptr) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    return {reinterpret_cast<const unsigned char*>(NetworkBridgeAccess::evalFile(network).netDescription.data()),
            NetworkBridgeAccess::evalFile(network).netDescription.size()};
}

ZfishByteView zfish_network_embedded_bytes() {
    return {reinterpret_cast<const unsigned char*>(gEmbeddedNNUEData), std::size_t(gEmbeddedNNUESize)};
}

void zfish_network_mark_initialized(void* network_ptr) {
    auto& network = *static_cast<Network*>(network_ptr);
    NetworkBridgeAccess::markInitialized(network);
}

void zfish_network_set_loaded_state(void*                network_ptr,
                                    const unsigned char* current_name_ptr,
                                    std::size_t          current_name_len,
                                    const unsigned char* description_ptr,
                                    std::size_t          description_len) {
    auto& eval_file = NetworkBridgeAccess::evalFile(*static_cast<Network*>(network_ptr));
    eval_file.current = std::string(reinterpret_cast<const char*>(current_name_ptr), current_name_len);
    eval_file.netDescription =
      std::string(reinterpret_cast<const char*>(description_ptr), description_len);
}

bool zfish_network_is_initialized(const void* network_ptr) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    return NetworkBridgeAccess::isInitialized(network);
}

std::uint32_t zfish_network_hash_value() { return NetworkBridgeAccess::hashValue(); }

std::size_t zfish_network_feature_transformer_read_blob(void*                network_ptr,
                                                        const unsigned char* data_ptr,
                                                        std::size_t          data_len) {
    auto& network = *static_cast<Network*>(network_ptr);
    return read_parameters_blob(data_ptr, data_len, NetworkBridgeAccess::featureTransformer(network));
}

std::size_t zfish_network_layer_read_blob(void*                network_ptr,
                                          std::size_t         bucket,
                                          const unsigned char* data_ptr,
                                          std::size_t          data_len) {
    auto& network = *static_cast<Network*>(network_ptr);
    return read_parameters_blob(data_ptr, data_len, NetworkBridgeAccess::layer(network, bucket));
}

ZfishOwnedByteView zfish_network_feature_transformer_write_blob(const void* network_ptr) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    const auto  bytes = write_parameters_blob(NetworkBridgeAccess::featureTransformer(network));
    if (!bytes.has_value())
        return {nullptr, 0};

    auto* copy = static_cast<unsigned char*>(std::malloc(bytes->size()));
    if (!copy)
        return {nullptr, 0};

    std::memcpy(copy, bytes->data(), bytes->size());
    return {copy, bytes->size()};
}

ZfishOwnedByteView zfish_network_layer_write_blob(const void* network_ptr, std::size_t bucket) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    const auto  bytes = write_parameters_blob(NetworkBridgeAccess::layer(network, bucket));
    if (!bytes.has_value())
        return {nullptr, 0};

    auto* copy = static_cast<unsigned char*>(std::malloc(bytes->size()));
    if (!copy)
        return {nullptr, 0};

    std::memcpy(copy, bytes->data(), bytes->size());
    return {copy, bytes->size()};
}

std::size_t zfish_network_feature_transformer_content_hash(const void* network_ptr) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    return NetworkBridgeAccess::featureTransformer(network).get_content_hash();
}

std::size_t zfish_network_layer_content_hash(const void* network_ptr, std::size_t bucket) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    return NetworkBridgeAccess::layer(network, bucket).get_content_hash();
}

std::size_t zfish_network_eval_file_content_hash(const void* network_ptr) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    return std::hash<EvalFile>{}(NetworkBridgeAccess::evalFile(network));
}

int zfish_network_transform_bucket(const void* network_ptr,
                                                                     const void* pos_ptr,
                                                                     void*       accumulator_stack_ptr,
                                                                     void*       cache_ptr,
                                                                     std::size_t bucket,
                                                                     unsigned char* transformed_ptr) {
        const auto& network = *static_cast<const Network*>(network_ptr);
        const auto& pos = *static_cast<const Position*>(pos_ptr);
        auto&       accumulator_stack = *static_cast<AccumulatorStack*>(accumulator_stack_ptr);
        auto&       cache = *static_cast<AccumulatorCaches*>(cache_ptr);
        auto*       transformed_features = reinterpret_cast<TransformedFeatureType*>(transformed_ptr);

        return static_cast<int>(NetworkBridgeAccess::featureTransformer(network).transform(
            pos, accumulator_stack, cache, transformed_features, bucket));
}

int zfish_network_propagate_bucket(const void*         network_ptr,
                                                                     std::size_t        bucket,
                                                                     const unsigned char* transformed_ptr) {
        const auto& network = *static_cast<const Network*>(network_ptr);
        const auto* transformed_features = reinterpret_cast<const TransformedFeatureType*>(transformed_ptr);

        return static_cast<int>(NetworkBridgeAccess::layer(network, bucket).propagate(
            transformed_features));
}

ZfishNetworkVerifyInfo zfish_network_verify_info(const void* network_ptr) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    const auto& feature_transformer = NetworkBridgeAccess::featureTransformer(network);
    const auto& layer = NetworkBridgeAccess::layer(network, 0);
    return {sizeof(feature_transformer) + sizeof(NetworkArchitecture) * LayerStacks,
            feature_transformer.InputDimensions,
            layer.TransformedFeatureDimensions,
            layer.FC_0_OUTPUTS,
            layer.FC_1_OUTPUTS};
}
}











void Network::load(const std::string& rootDirectory, std::string evalfilePath) {
    zfish_network_load(this,
                       reinterpret_cast<const unsigned char*>(rootDirectory.data()),
                       rootDirectory.size(),
                       reinterpret_cast<const unsigned char*>(evalfilePath.data()),
                       evalfilePath.size());
}

bool Network::save(const std::optional<std::string>& filename) const {
    const std::string filenameText = filename.value_or(std::string{});
    const auto        result = zfish_network_save(this,
                                           static_cast<std::uint8_t>(filename.has_value()),
                                           reinterpret_cast<const unsigned char*>(filenameText.data()),
                                           filenameText.size());

    if (result.message)
    {
        sync_cout << result.message << sync_endl;
        std::free(const_cast<char*>(result.message));
    }

    return result.saved != 0;
}

NetworkOutput Network::evaluate(const Position&    pos,
                                AccumulatorStack&  accumulatorStack,
                                AccumulatorCaches& cache) const {
    const auto output = zfish_network_evaluate(this, &pos, &accumulatorStack, &cache);
    return {static_cast<Value>(output.psqt), static_cast<Value>(output.positional)};
}

void Network::verify(std::string                                  evalfilePath,
                     const std::function<void(std::string_view)>& f) const {
    const auto result = zfish_network_verify(this,
                                             reinterpret_cast<const unsigned char*>(evalfilePath.data()),
                                             evalfilePath.size());

    if (f && result.message)
        f(result.message);

    if (result.message)
        std::free(const_cast<char*>(result.message));

    if (result.should_exit)
        exit(EXIT_FAILURE);
}

NnueEvalTrace Network::trace_evaluate(const Position&    pos,
                                      AccumulatorStack&  accumulatorStack,
                                      AccumulatorCaches& cache) const {
    const auto output = zfish_network_trace_evaluate(this, &pos, &accumulatorStack, &cache);

    NnueEvalTrace trace{};
    trace.correctBucket = output.correct_bucket;
    for (IndexType bucket = 0; bucket < LayerStacks; ++bucket)
    {
        trace.psqt[bucket] = output.psqt[bucket];
        trace.positional[bucket] = output.positional[bucket];
    }

    return trace;
}

std::size_t Network::get_content_hash() const {
    return zfish_network_content_hash(this);
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

struct ZfishMovePickerState {
    std::uint16_t      tt_move_raw;
    int                stage;
    int                threshold;
    int                depth;
    std::uint8_t       skip_quiets;
    std::size_t        cur;
    std::size_t        end_cur;
    std::size_t        end_bad_captures;
    std::size_t        end_captures;
    std::size_t        end_generated;
    ZfishMoveSortEntry moves[Stockfish::MAX_MOVES];
};

struct ZfishMovePickerContext {
    const void* pos;
    const void* main_history;
    const void* low_ply_history;
    const void* capture_history;
    const void* continuation_history;
    const void* shared_history;
    int         ply;
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

struct ZfishBitboardMagicInitEntry {
    std::uint64_t mask;
    std::uint64_t magic;
    unsigned      shift;
    std::size_t   attack_offset;
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
int zfish_movepick_init_main_stage(std::uint8_t has_checkers,
                                   std::uint8_t has_tt_move,
                                   int          depth);
int zfish_movepick_init_probcut_stage(std::uint8_t has_tt_move);
std::uint16_t zfish_movepick_next_move(ZfishMovePickerState*         state,
                                       const ZfishMovePickerContext* context);
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

struct ZfishTbConfig {
    int          cardinality;
    std::uint8_t root_in_tb;
    std::uint8_t use_rule50;
    int          probe_depth;
};

std::size_t zfish_thread_next_power_of_two(std::uint64_t count);
std::size_t zfish_thread_pick_best_thread(const ZfishThreadSummary* summaries,
                                          std::size_t               count);
void         zfish_thread_start_thinking(void*        pool,
                                         const void*  options,
                                         void*        pos,
                                         const void*  limits,
                                         const void*  setup_state);
void zfish_bitboards_init_runtime(std::uint8_t         (*popcnt16_ptr)[1 << 16],
                                  std::uint8_t         (*square_distance_ptr)[64][64],
                                  std::uint64_t        (*line_bb_ptr)[64][64],
                                  std::uint64_t        (*between_bb_ptr)[64][64],
                                  std::uint64_t        (*ray_pass_bb_ptr)[64][64]);
void zfish_bitboards_init_magics_runtime(
    ZfishBitboardMagicInitEntry (*entries_ptr)[64][2],
    std::uint64_t*               rook_table_ptr,
    std::uint64_t*               bishop_table_ptr);
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

template<GenType Type>
std::size_t score_move_list(const Position&              pos,
                            const ButterflyHistory*      mainHistory,
                            const LowPlyHistory*         lowPlyHistory,
                            const CapturePieceToHistory* captureHistory,
                            const PieceToHistory* const* continuationHistory,
                            const SharedHistories*       sharedHistory,
                            int                          ply,
                            const MoveList<Type>&        ml,
                            ZfishMoveSortEntry*          outputs) {

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
    return count;
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
        cur(moves),
        endCur(moves),
        endBadCaptures(moves),
        endCaptures(moves),
        endGenerated(moves),
        threshold(0),
    depth(d),
    ply(pl) {

        stage = zfish_movepick_init_main_stage(
            std::uint8_t(pos.checkers() ? 1 : 0),
            std::uint8_t(ttm && pos.pseudo_legal(ttm) ? 1 : 0),
            depth);
}

MovePicker::MovePicker(const Position& p, Move ttm, int th, const CapturePieceToHistory* cph) :
    pos(p),
        mainHistory(nullptr),
        lowPlyHistory(nullptr),
    captureHistory(cph),
        continuationHistory(nullptr),
        sharedHistory(nullptr),
    ttMove(ttm),
        cur(moves),
        endCur(moves),
        endBadCaptures(moves),
        endCaptures(moves),
        endGenerated(moves),
        threshold(th),
        depth(0),
        ply(0) {
    assert(!pos.checkers());

        stage = zfish_movepick_init_probcut_stage(
            std::uint8_t(ttm && pos.capture_stage(ttm) && pos.pseudo_legal(ttm) ? 1 : 0));
}

template<GenType Type>
ExtMove* MovePicker::score(const MoveList<Type>& ml) {

    ZfishMoveSortEntry  outputs[MAX_MOVES]{};
    const std::size_t   count = score_move_list<Type>(
      pos, mainHistory, lowPlyHistory, captureHistory, continuationHistory, sharedHistory, ply, ml,
      outputs);

    ExtMove* it = cur;
    for (std::size_t i = 0; i < count; ++i)
    {
        ExtMove& move = *it++;
        move          = Move(outputs[i].raw_move);
        move.value    = outputs[i].value;
    }
    return it;
}

Move MovePicker::next_move() {

    ZfishMovePickerState state{};
    state.tt_move_raw      = ttMove.raw();
    state.stage            = stage;
    state.threshold        = threshold;
    state.depth            = depth;
    state.skip_quiets      = std::uint8_t(skipQuiets ? 1 : 0);
    state.cur              = static_cast<std::size_t>(cur - moves);
    state.end_cur          = static_cast<std::size_t>(endCur - moves);
    state.end_bad_captures = static_cast<std::size_t>(endBadCaptures - moves);
    state.end_captures     = static_cast<std::size_t>(endCaptures - moves);
    state.end_generated    = static_cast<std::size_t>(endGenerated - moves);

    const auto usedBefore = std::max(
      {state.cur, state.end_cur, state.end_bad_captures, state.end_captures, state.end_generated});

    for (std::size_t i = 0; i < usedBefore; ++i)
    {
        state.moves[i].raw_move = moves[i].raw();
        state.moves[i].reserved = 0;
        state.moves[i].value    = moves[i].value;
    }

    const ZfishMovePickerContext context = {
        .pos                  = &pos,
        .main_history         = mainHistory,
        .low_ply_history      = lowPlyHistory,
        .capture_history      = captureHistory,
        .continuation_history = continuationHistory,
        .shared_history       = sharedHistory,
        .ply                  = ply,
    };

    const Move result = Move(zfish_movepick_next_move(&state, &context));

    ttMove         = Move(state.tt_move_raw);
    stage          = state.stage;
    threshold      = state.threshold;
    depth          = Depth(state.depth);
    skipQuiets     = state.skip_quiets != 0;
    cur            = moves + state.cur;
    endCur         = moves + state.end_cur;
    endBadCaptures = moves + state.end_bad_captures;
    endCaptures    = moves + state.end_captures;
    endGenerated   = moves + state.end_generated;

    const auto usedAfter = std::max(
      {state.cur, state.end_cur, state.end_bad_captures, state.end_captures, state.end_generated});

    for (std::size_t i = 0; i < usedAfter; ++i)
    {
        moves[i]       = Move(state.moves[i].raw_move);
        moves[i].value = state.moves[i].value;
    }

    return result;
}

void MovePicker::skip_quiet_moves() { skipQuiets = true; }

extern "C" std::size_t zfish_movepick_score_captures(const void* pos_ptr,
                                                      const void* capture_history_ptr,
                                                      ZfishMoveSortEntry* outputs) {
    const auto& pos            = *static_cast<const Position*>(pos_ptr);
    const auto* captureHistory = static_cast<const CapturePieceToHistory*>(capture_history_ptr);
    MoveList<CAPTURES> ml(pos);
    return score_move_list<CAPTURES>(
      pos, nullptr, nullptr, captureHistory, nullptr, nullptr, 0, ml, outputs);
}

extern "C" std::size_t zfish_movepick_score_quiets(const void* pos_ptr,
                                                    const void* main_history_ptr,
                                                    const void* low_ply_history_ptr,
                                                    const void* continuation_history_ptr,
                                                    const void* shared_history_ptr,
                                                    int         ply,
                                                    ZfishMoveSortEntry* outputs) {
    const auto& pos                 = *static_cast<const Position*>(pos_ptr);
    const auto* mainHistory         = static_cast<const ButterflyHistory*>(main_history_ptr);
    const auto* lowPlyHistory       = static_cast<const LowPlyHistory*>(low_ply_history_ptr);
        const auto* continuationHistory =
            static_cast<const PieceToHistory* const*>(continuation_history_ptr);
    const auto* sharedHistory       = static_cast<const SharedHistories*>(shared_history_ptr);
    MoveList<QUIETS> ml(pos);
    return score_move_list<QUIETS>(
      pos, mainHistory, lowPlyHistory, nullptr, continuationHistory, sharedHistory, ply, ml,
      outputs);
}

extern "C" std::size_t zfish_movepick_score_evasions(const void* pos_ptr,
                                                      const void* main_history_ptr,
                                                      const void* continuation_history_ptr,
                                                      ZfishMoveSortEntry* outputs) {
    const auto& pos                 = *static_cast<const Position*>(pos_ptr);
    const auto* mainHistory         = static_cast<const ButterflyHistory*>(main_history_ptr);
        const auto* continuationHistory =
            static_cast<const PieceToHistory* const*>(continuation_history_ptr);
    MoveList<EVASIONS> ml(pos);
    return score_move_list<EVASIONS>(
      pos, mainHistory, nullptr, nullptr, continuationHistory, nullptr, 0, ml, outputs);
}

extern "C" std::uint8_t zfish_movepick_see_ge(const void* pos_ptr,
                                               std::uint16_t raw_move,
                                               int           threshold) {
    const auto& pos = *static_cast<const Position*>(pos_ptr);
    return std::uint8_t(pos.see_ge(Move(raw_move), threshold) ? 1 : 0);
}

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

std::size_t zfish_limits_searchmove_count(const void* limits_ptr) {
    return static_cast<const Search::LimitsType*>(limits_ptr)->searchmoves.size();
}

ZfishSearchMoveView zfish_limits_searchmove_text(const void* limits_ptr, std::size_t index) {
    const auto& searchmoves = static_cast<const Search::LimitsType*>(limits_ptr)->searchmoves;
    assert(index < searchmoves.size());
    const auto& text = searchmoves[index];
    return {reinterpret_cast<const unsigned char*>(text.data()), text.size()};
}

std::uint16_t zfish_uci_to_move_raw(const void*          pos_ptr,
                                    const unsigned char* text_ptr,
                                    std::size_t          text_len) {
    if (!text_ptr && text_len == 0)
        return Move::none().raw();

    std::string text(reinterpret_cast<const char*>(text_ptr), text_len);
    return UCIEngine::to_move(*static_cast<const Position*>(pos_ptr), std::move(text)).raw();
}

std::uint16_t zfish_move_none_raw() { return Move::none().raw(); }

std::size_t zfish_position_collect_legal_move_raws(const void*    pos_ptr,
                                                   std::uint16_t* out_moves,
                                                   std::size_t    capacity) {
    const auto& pos = *static_cast<const Position*>(pos_ptr);
    std::size_t count = 0;
    for (const auto& move : MoveList<LEGAL>(pos))
    {
        assert(count < capacity);
        out_moves[count++] = move.raw();
    }
    return count;
}

void* zfish_root_moves_create(const std::uint16_t* move_raws, std::size_t count) {
    auto root_moves = std::make_unique<Search::RootMoves>();
    root_moves->reserve(count);
    for (std::size_t index = 0; index < count; ++index)
        root_moves->emplace_back(Move(move_raws[index]));
    return root_moves.release();
}

void zfish_root_moves_destroy(void* root_moves_ptr) {
    delete static_cast<Search::RootMoves*>(root_moves_ptr);
}

ZfishTbConfig zfish_threadpool_rank_root_moves(const void* options_ptr,
                                               void*       pos_ptr,
                                               void*       root_moves_ptr) {
    const auto config = Tablebases::rank_root_moves(*static_cast<const OptionsMap*>(options_ptr),
                                                    *static_cast<Position*>(pos_ptr),
                                                    *static_cast<Search::RootMoves*>(root_moves_ptr));
    return {config.cardinality, static_cast<std::uint8_t>(config.rootInTB),
            static_cast<std::uint8_t>(config.useRule50), config.probeDepth};
}

std::size_t zfish_threadpool_thread_count(const void* pool_ptr) {
    return static_cast<const ThreadPool*>(pool_ptr)->size();
}

void* zfish_threadpool_thread_at(void* pool_ptr, std::size_t index) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    assert(index < pool->size());
    return (*(pool->begin() + static_cast<std::ptrdiff_t>(index))).get();
}

void zfish_threadpool_wait_main_thread(void* pool_ptr) {
    static_cast<ThreadPool*>(pool_ptr)->main_thread()->wait_for_search_finished();
}

void zfish_threadpool_reset_start_state(void* pool_ptr, std::uint8_t ponder_mode) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->stopOnPonderhit = pool->stop = false;
    pool->main_manager()->ponder          = ponder_mode != 0;
    pool->increaseDepth                   = true;
}

void zfish_thread_run_root_setup(void*         thread_ptr,
                                 const void*   limits_ptr,
                                 const void*   root_moves_ptr,
                                 const void*   pos_ptr,
                                 const void*   setup_state_ptr,
                                 ZfishTbConfig tb_config) {
    auto* thread = static_cast<Thread*>(thread_ptr);
    const auto limits = *static_cast<const Search::LimitsType*>(limits_ptr);
    const auto root_moves = *static_cast<const Search::RootMoves*>(root_moves_ptr);
    const auto* pos = static_cast<const Position*>(pos_ptr);
    const auto setup_state = *static_cast<const StateInfo*>(setup_state_ptr);
    const auto fen = pos->fen();
    const bool chess960 = pos->is_chess960();
    const Tablebases::Config config{tb_config.cardinality, tb_config.root_in_tb != 0,
                                    tb_config.use_rule50 != 0, Depth(tb_config.probe_depth)};

    thread->run_custom_job([thread, limits, root_moves, fen = std::move(fen), chess960,
                            setup_state, config]() {
        auto* worker = bridge_worker(thread);
        worker->limits          = limits;
        worker->nodes           = 0;
        worker->tbHits          = 0;
        worker->bestMoveChanges = 0;
        worker->nmpMinPly       = 0;
        worker->rootDepth       = 0;
        worker->rootMoves       = root_moves;
        worker->rootPos.set(fen, chess960, &worker->rootState);
        worker->rootState = setup_state;
        worker->tbConfig  = config;
    });
}

void zfish_thread_wait_for_search_finished(void* thread_ptr) {
    static_cast<Thread*>(thread_ptr)->wait_for_search_finished();
}

void zfish_thread_start_searching(void* thread_ptr) {
    static_cast<Thread*>(thread_ptr)->start_searching();
}

void* zfish_engine_states_reset(void* states_ptr) {
    auto& states = *static_cast<StateListPtr*>(states_ptr);
    states       = StateListPtr(new std::deque<StateInfo>(1));
    return &states->back();
}

void* zfish_engine_states_push(void* states_ptr) {
    auto& states = *static_cast<StateListPtr*>(states_ptr);
    states->emplace_back();
    return &states->back();
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

void zfish_engine_threads_set_stop(void* threads_ptr) {
    static_cast<ThreadPool*>(threads_ptr)->stop = true;
}

void zfish_engine_numa_set_system(void* numa_context_ptr, std::uint8_t hardware) {
    auto& numa_context = *static_cast<NumaReplicationContext*>(numa_context_ptr);
    if (hardware != 0)
        numa_context.set_numa_config(NumaConfig::from_system(DefaultNumaPolicy, false));
    else
        numa_context.set_numa_config(NumaConfig::from_system(DefaultNumaPolicy));
}

void zfish_engine_numa_set_none(void* numa_context_ptr) {
    static_cast<NumaReplicationContext*>(numa_context_ptr)->set_numa_config(NumaConfig{});
}

void zfish_engine_numa_set_from_string(void*                numa_context_ptr,
                                       const unsigned char* text_ptr,
                                       std::size_t          text_len) {
    auto& numa_context = *static_cast<NumaReplicationContext*>(numa_context_ptr);
    numa_context.set_numa_config(
      NumaConfig::from_string(std::string(reinterpret_cast<const char*>(text_ptr), text_len)));
}

void zfish_engine_threadpool_wait_finished(void* threads_ptr) {
    static_cast<ThreadPool*>(threads_ptr)->wait_for_search_finished();
}

void zfish_engine_threads_reconfigure(void*       threads_ptr,
                                      const void* numa_context_ptr,
                                      const void* options_ptr,
                                      void*       tt_ptr,
                                      void*       shared_hists_ptr,
                                      void*       network_ptr,
                                      const void* update_context_ptr) {
    auto&       threads = *static_cast<ThreadPool*>(threads_ptr);
    const auto& numa_context = *static_cast<const NumaReplicationContext*>(numa_context_ptr);
    const auto& options = *static_cast<const OptionsMap*>(options_ptr);
    auto&       tt = *static_cast<TranspositionTable*>(tt_ptr);
    auto&       shared_hists = *static_cast<std::map<NumaIndex, SharedHistories>*>(shared_hists_ptr);
    auto&       network = *static_cast<LazyNumaReplicatedSystemWide<Eval::NNUE::Network>*>(network_ptr);
    const auto& update_context =
      *static_cast<const Search::SearchManager::UpdateContext*>(update_context_ptr);

    threads.set(numa_context.get_numa_config(), {options, threads, tt, shared_hists, network},
                update_context);
}

std::size_t zfish_engine_option_hash_value(const void* options_ptr) {
    return static_cast<std::size_t>((*static_cast<const OptionsMap*>(options_ptr))["Hash"]);
}

void zfish_engine_threads_ensure_network_replicated(void* threads_ptr) {
    static_cast<ThreadPool*>(threads_ptr)->ensure_network_replicated();
}

void zfish_engine_threads_wait_finished(void* threads_ptr) {
    static_cast<ThreadPool*>(threads_ptr)->main_thread()->wait_for_search_finished();
}

void zfish_engine_tt_resize(void* tt_ptr, std::size_t mb, void* threads_ptr) {
    static_cast<TranspositionTable*>(tt_ptr)->resize(mb, *static_cast<ThreadPool*>(threads_ptr));
}

void zfish_engine_main_manager_set_ponder(void* threads_ptr, std::uint8_t ponder) {
    static_cast<ThreadPool*>(threads_ptr)->main_manager()->ponder = ponder != 0;
}

void zfish_engine_tt_clear(void* tt_ptr, void* threads_ptr) {
    static_cast<TranspositionTable*>(tt_ptr)->clear(*static_cast<ThreadPool*>(threads_ptr));
}

void zfish_engine_threads_clear(void* threads_ptr) {
    static_cast<ThreadPool*>(threads_ptr)->clear();
}

void zfish_engine_tablebases_init(const unsigned char* path_ptr, std::size_t path_len) {
    Tablebases::init(std::string(reinterpret_cast<const char*>(path_ptr), path_len));
}

void zfish_engine_position_summary(const void* pos_ptr, ZfishEnginePositionSummary* out) {
    const auto& pos = *static_cast<const Position*>(pos_ptr);
    *out            = {
      .side_to_move_white = static_cast<std::uint8_t>(pos.side_to_move() == WHITE ? 1 : 0),
      .checkers           = pos.checkers(),
      .key                = pos.key(),
      .material           = 534 * pos.count<PAWN>() + pos.non_pawn_material(),
      .rule50_count       = pos.rule50_count(),
    };
}

const char* zfish_engine_position_fen(const void* pos_ptr) {
    const auto fen = static_cast<const Position*>(pos_ptr)->fen();
    auto*      out = static_cast<char*>(std::malloc(fen.size() + 1));
    if (!out)
        return nullptr;

    std::memcpy(out, fen.c_str(), fen.size() + 1);
    return out;
}

ZfishEngineTablebaseProbe zfish_engine_position_probe_tablebases(const void* pos_ptr) {
    const auto& pos = *static_cast<const Position*>(pos_ptr);
    if (Tablebases::MaxCardinality < popcount(pos.pieces()) || pos.can_castle(ANY_CASTLING))
        return {};

    StateInfo p_state;
    Position  probe_pos;
    probe_pos.set(pos.fen(), pos.is_chess960(), &p_state);

    Tablebases::ProbeState wdl_state = Tablebases::FAIL;
    Tablebases::ProbeState dtz_state = Tablebases::FAIL;
    const auto             wdl       = Tablebases::probe_wdl(probe_pos, &wdl_state);
    const auto             dtz       = Tablebases::probe_dtz(probe_pos, &dtz_state);

    return {
      .available = 1,
      .wdl       = static_cast<int>(wdl),
      .wdl_state = static_cast<int>(wdl_state),
      .dtz       = dtz,
      .dtz_state = static_cast<int>(dtz_state),
    };
}

void* zfish_engine_accumulator_stack_create() {
    return new (std::nothrow) Eval::NNUE::AccumulatorStack();
}

void zfish_engine_accumulator_stack_destroy(void* stack_ptr) {
    delete static_cast<Eval::NNUE::AccumulatorStack*>(stack_ptr);
}

void* zfish_engine_accumulator_caches_create(const void* network_ptr) {
    return new (std::nothrow)
      Eval::NNUE::AccumulatorCaches(*static_cast<const Eval::NNUE::Network*>(network_ptr));
}

void zfish_engine_accumulator_caches_destroy(void* caches_ptr) {
    delete static_cast<Eval::NNUE::AccumulatorCaches*>(caches_ptr);
}

}

void ThreadPool::start_thinking(const OptionsMap&  options,
                                Position&          pos,
                                StateListPtr&      states,
                                Search::LimitsType limits) {
    assert(states.get() || setupStates.get());

    if (states.get())
        setupStates = std::move(states);

    zfish_thread_start_thinking(this, &options, &pos, &limits, &setupStates->back());
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

#include "uci_bridge/misc_text.inc"

#include "uci_bridge/engine_numa_text.inc"

#include "uci_bridge/engine_network_helpers.inc"

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

struct EngineMoveView {
    const unsigned char* ptr;
    std::size_t          len;
};

extern "C" {
const char* zfish_engine_set_position(void*                pos,
                                      void*                states,
                                      std::uint8_t         chess960_enabled,
                                      const unsigned char* fen_ptr,
                                      std::size_t          fen_len,
                                      const EngineMoveView* moves_ptr,
                                      std::size_t          move_count);
void        zfish_engine_stop(void* threads);
void        zfish_engine_search_clear(void*                threads,
                                      void*                tt,
                                      const unsigned char* syzygy_path_ptr,
                                      std::size_t          syzygy_path_len);
}

std::uint64_t Engine::perft(const std::string& fen, Depth depth, bool isChess960) {
    verify_network();

    return Benchmark::perft(fen, depth, isChess960);
}

void Engine::go(Search::LimitsType& limits) {
    assert(limits.perft == 0);
    verify_network();

    threads.start_thinking(options, pos, states, limits);
}

void Engine::set_on_update_no_moves(std::function<void(const Engine::InfoShort&)>&& f) {
    updateContext.onUpdateNoMoves = std::move(f);
}

void Engine::set_on_update_full(std::function<void(const Engine::InfoFull&)>&& f) {
    updateContext.onUpdateFull = std::move(f);
}

void Engine::set_on_iter(std::function<void(const Engine::InfoIter&)>&& f) {
    updateContext.onIter = std::move(f);
}

void Engine::set_on_bestmove(std::function<void(std::string_view, std::string_view)>&& f) {
    updateContext.onBestmove = std::move(f);
}

void Engine::set_on_verify_network(std::function<void(std::string_view)>&& f) {
    onVerifyNetwork = std::move(f);
}

void Engine::wait_for_search_finished() { threads.main_thread()->wait_for_search_finished(); }

std::optional<PositionSetError> Engine::set_position(const std::string&              fen,
                                                     const std::vector<std::string>& moves) {
    std::vector<EngineMoveView> move_views;
    move_views.reserve(moves.size());
    for (const auto& move : moves)
        move_views.push_back({reinterpret_cast<const unsigned char*>(move.data()), move.size()});

    const char* error = zfish_engine_set_position(
      &pos, &states, static_cast<std::uint8_t>(static_cast<int>(options["UCI_Chess960"])),
      reinterpret_cast<const unsigned char*>(fen.data()), fen.size(),
      move_views.empty() ? nullptr : move_views.data(), move_views.size());
    if (!error)
        return std::nullopt;

    return PositionSetError(take_string_and_free_engine_required(error));
}

void Engine::stop() { zfish_engine_stop(&threads); }

void Engine::set_numa_config_from_option(const std::string& o) {
    zfish_engine_set_numa_config_from_option(
      &numaContext,
      &options,
      &threads,
      &tt,
      &sharedHists,
      &network,
      &updateContext,
      reinterpret_cast<const unsigned char*>(o.data()),
      o.size());
}

void Engine::resize_threads() {
    zfish_engine_resize_threads(&numaContext, &options, &threads, &tt, &sharedHists, &network,
                                &updateContext);
}

void Engine::set_tt_size(size_t mb) { zfish_engine_set_tt_size(&threads, &tt, mb); }

void Engine::set_ponderhit(bool b) {
    zfish_engine_set_ponderhit(&threads, static_cast<std::uint8_t>(b ? 1 : 0));
}

void Engine::search_clear() {
    const auto syzygy_path = std::string(options["SyzygyPath"]);
    zfish_engine_search_clear(&threads, &tt,
                              reinterpret_cast<const unsigned char*>(syzygy_path.data()),
                              syzygy_path.size());
}

void Engine::trace_eval() const {
    StateListPtr trace_states(new std::deque<StateInfo>(1));
    Position     p;
    p.set(pos.fen(), options["UCI_Chess960"], &trace_states->back());

    verify_network();

    sync_cout << "\n" << Eval::trace(p, *network) << sync_endl;
}

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
std::array<Bitboard, 0x19000> RookTable;
std::array<Bitboard, 0x1480>  BishopTable;
ZfishBitboardMagicInitEntry    BitboardMagicEntries[SQUARE_NB][2];

void assign_magic_entries() {
    for (Square s = SQ_A1; s <= SQ_H8; ++s)
        for (int idx = 0; idx < 2; ++idx)
        {
            const auto& entry = BitboardMagicEntries[s][idx];
            auto&       magic = Magics[s][idx];

            magic.mask  = entry.mask;
            magic.magic = entry.magic;
            magic.shift = entry.shift;
            magic.attacks = (idx == 0 ? BishopTable.data() : RookTable.data()) + entry.attack_offset;
        }
}

}  // namespace

const OptionsMap& Engine::get_options() const { return options; }
OptionsMap&       Engine::get_options() { return options; }

std::string Engine::fen() const { return pos.fen(); }

void Engine::flip() { pos.flip(); }

std::string Engine::visualize() const {
    return take_string_and_free_required(zfish_engine_visualize(&pos));
}

int Engine::get_hashfull(int maxAge) const { return tt.hashfull(maxAge); }

std::string Eval::trace(Position& pos, const Eval::NNUE::Network& network) {
    return take_string_and_free_required(zfish_engine_eval_trace(&pos, &network));
}

extern "C" {

#include "uci_bridge/position_runtime_exports.inc"

}

namespace Bitboards {

void init() {
    zfish_bitboards_init_magics_runtime(&BitboardMagicEntries, RookTable.data(), BishopTable.data());
    assign_magic_entries();

    zfish_bitboards_init_runtime(&PopCnt16, &SquareDistance, &LineBB, &BetweenBB, &RayPassBB);
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
