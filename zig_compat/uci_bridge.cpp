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

#define private public
#include "uci.h"

#include <algorithm>
#include <array>
#include <atomic>
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
const char* zfish_engine_evalfile_text(const void* engine_ptr);
const char* zfish_engine_numa_config_text(const void* engine_ptr);
void*       zfish_engine_position_ptr(void* engine_ptr);
const void* zfish_engine_options_ptr(const void* engine_ptr);
void*       zfish_engine_numa_context_ptr(void* engine_ptr);
void*       zfish_engine_states_slot_ptr(void* engine_ptr);
void        zfish_engine_states_slot_reset(void* states_slot_ptr);
const void* zfish_engine_network_ptr(const void* engine_ptr);
void*       zfish_engine_threads_ptr(void* engine_ptr);
std::uint8_t zfish_engine_chess960_enabled(const void* engine_ptr);
std::size_t  zfish_limits_perft_value(const void* limits_ptr);
void zfish_engine_emit_verify_message(const void*          engine_ptr,
                                      const unsigned char* message_ptr,
                                      std::size_t          message_len);
void zfish_engine_verify_network_method(const void* engine_ptr);
const char* zfish_engine_set_position_owner(void*                engine_ptr,
                                            const unsigned char* fen_ptr,
                                            std::size_t          fen_len,
                                            const void*          moves_ptr,
                                            std::size_t          move_count);
const char* zfish_engine_numa_config_information_owner(const void* engine_ptr);
const char* zfish_engine_thread_allocation_information_owner(const void* engine_ptr);
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
void         zfish_engine_release_pending_state_slot(void* states_slot);
const char* zfish_engine_fen(const void* pos);
const char* zfish_misc_engine_version_info_text();
const char* zfish_misc_engine_info_mode(std::uint8_t to_uci);
const char* zfish_misc_compiler_info_text();
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

}  // namespace





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

// The NNUE feature-transformer forward pass (transform) is now Zig-owned
// (zfish_network_transform_bucket in zig_src/main.zig). The bridge only exposes
// the FeatureTransformer pointer so the Zig accumulator evaluate can read its
// weights -- the same pointer the C++ AccumulatorStack::evaluate passed.
const void* zfish_network_feature_transformer_ptr(const void* network_ptr) {
        const auto& network = *static_cast<const Network*>(network_ptr);
        return &NetworkBridgeAccess::featureTransformer(network);
}

// Per-bucket affine-layer weight/bias pointers for the Zig propagate
// (zfish_network_propagate_bucket in network.zig). idx 0=fc_0, 1=fc_1, 2=fc_2.
// Biases are stored linearly (int32); weights are int8 in the SSSE3-scrambled
// layout, which the Zig side un-scrambles with get_weight_index_scrambled.
const std::int32_t* zfish_layer_biases(const void* network_ptr, std::size_t bucket, int idx) {
        const auto& l = NetworkBridgeAccess::layer(*static_cast<const Network*>(network_ptr), bucket);
        return idx == 0 ? l.fc_0.biases : idx == 1 ? l.fc_1.biases : l.fc_2.biases;
}

const std::int8_t* zfish_layer_weights(const void* network_ptr, std::size_t bucket, int idx) {
        const auto& l = NetworkBridgeAccess::layer(*static_cast<const Network*>(network_ptr), bucket);
        return idx == 0 ? l.fc_0.weights : idx == 1 ? l.fc_1.weights : l.fc_2.weights;
}

// zfish_network_propagate_bucket is now Zig-owned (network.zig). The bridge only
// exposes the per-layer weight/bias pointers above.

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

extern "C" std::uint8_t zfish_search_is_shuffling(const void* pos_ptr, const void* ss_ptr,
                                                 std::uint16_t move);
extern "C" void zfish_search_update_continuation_histories(void* ss_ptr, std::uint8_t pc,
                                                           std::uint8_t to, int bonus);
extern "C" void zfish_search_update_quiet_histories(void* worker_ptr, const void* pos_ptr,
                                                    void* ss_ptr, std::uint16_t move, int bonus);
extern "C" void zfish_search_update_all_stats(
  void* worker_ptr, void* pos_ptr, void* ss_ptr, std::uint16_t best_move, int prev_sq,
  const std::uint16_t* quiets, std::size_t n_quiets, const std::uint16_t* captures,
  std::size_t n_captures, int depth, std::uint16_t tt_move);
extern "C" void zfish_search_update_correction_history(void* worker_ptr, const void* pos_ptr,
                                                       void* ss_ptr, int bonus);
extern "C" void zfish_search_fill_reductions(int* reductions, std::size_t count);
extern "C" int  zfish_search_stat_bonus(int depth, unsigned char is_tt_move, int prev_stat_score);
extern "C" int  zfish_search_stat_malus(int depth);
extern "C" int  zfish_search_correction_value(int pcv, int micv, int wnpcv, int bnpcv,
                                              int cch2, int cch4, unsigned char m_ok);
extern "C" int  zfish_search_conthist_delta(int bonus, int weight, int positive_count, int i);
extern "C" int  zfish_search_razor_margin(int depth);
extern "C" int  zfish_search_qsearch_stand_pat_blend(int best_value, int beta);
extern "C" int  zfish_search_qsearch_fail_high_blend(int best_value, int beta);
extern "C" int  zfish_search_eval_diff(int prev_static_eval, int static_eval);
extern "C" int  zfish_search_qsearch_futility_base(int static_eval);
extern "C" int  zfish_search_prior_conthist_scale(int scaled_bonus);
extern "C" int  zfish_search_prior_mainhist_scale(int scaled_bonus);
extern "C" int  zfish_search_prior_pawnhist_scale(int scaled_bonus);
extern "C" int  zfish_search_capture_stat_score(int piece_value, int capture_hist);
extern "C" int  zfish_search_quiet_stat_score(int main_hist, int cont0, int cont1);
extern "C" int  zfish_search_corrhist_bonus(int eval_delta, int depth, unsigned char has_best_move);
extern "C" int  zfish_search_aspiration_initial_delta(std::size_t thread_idx,
                                                      int mean_squared_score);
extern "C" int  zfish_search_aspiration_delta_grow(int delta);
extern "C" int  zfish_search_optimism(int avg);
extern "C" void zfish_search_age_main_history(void* worker_ptr);
extern "C" void zfish_search_fill_low_ply_history(void* worker_ptr);
extern "C" void zfish_search_clear_worker_histories(void* worker_ptr);
extern "C" void zfish_search_set_cont_hist(void* worker_ptr, void* ss_ptr, std::uint8_t in_check,
                                           std::uint8_t capture, std::uint8_t pc, std::uint8_t to);
extern "C" int  zfish_search_qsearch(void* worker, void* pos, void* ss, int alpha, int beta,
                                     std::uint8_t pv_node);
extern "C" int  zfish_search_search(void* worker, void* pos, void* ss, int alpha, int beta,
                                    int depth, std::uint8_t cut_node, std::uint8_t pv_node,
                                    std::uint8_t root_node);
extern "C" std::uint8_t zfish_search_iterative_deepening(void* worker);
extern "C" std::uint8_t zfish_search_extract_ponder_from_tt(void* pv, void* table,
                                                           std::size_t cc, std::uint8_t gen,
                                                           void* pos);
extern "C" void zfish_search_clear_shared_history(void* shared, std::size_t thread_idx,
                                                  std::size_t numa_total);
extern "C" void zfish_search_clear_refresh_cache(void* cache, const std::int16_t* biases);
extern "C" int  zfish_search_move_count_limit(int depth, unsigned char improving);
extern "C" int  zfish_search_capture_futility_value(int static_eval, int lmr_depth,
                                                    int piece_value, int capt_hist);
extern "C" int  zfish_search_capture_see_margin(int depth, int capt_hist);
extern "C" int  zfish_search_ttmh_depth_bonus(int depth);
extern "C" int  zfish_search_ttmh_match_bonus(unsigned char best_is_tt);
extern "C" int  zfish_search_prior_bonus_scale(int prev_stat_score, int depth,
                                               unsigned char prev_movecount_gt8,
                                               unsigned char cond_a, unsigned char cond_b);
extern "C" int  zfish_search_prior_scaled_bonus_base(int depth);
extern "C" int  zfish_search_lmr_ttpv_reduction(unsigned char pv_node, unsigned char value_gt_alpha,
                                                unsigned char depth_ge, unsigned char cut_node);
extern "C" int  zfish_search_lmr_corr_reduction(int correction_value);
extern "C" int  zfish_search_lmr_stat_score_reduction(int stat_score);
extern "C" int  zfish_search_lmr_all_node_scale(int r, int depth);
extern "C" int  zfish_search_singular_beta(int tt_value, unsigned char ttpv_and_not_pv, int depth);
extern "C" int  zfish_search_singular_double_margin(unsigned char pv_node,
                                                    unsigned char not_tt_capture,
                                                    int correction_value, int tt_move_history,
                                                    unsigned char ply_gt_root);
extern "C" int  zfish_search_singular_triple_margin(unsigned char pv_node,
                                                    unsigned char not_tt_capture, unsigned char ttpv,
                                                    int correction_value, unsigned char ply_gt_root);
extern "C" int  zfish_search_history_prune_threshold(int depth);
extern "C" int  zfish_search_quiet_futility_value(int static_eval, unsigned char no_best_move,
                                                  int lmr_depth, unsigned char eval_gt_alpha);
extern "C" int  zfish_search_quiet_see_margin(int lmr_depth);
extern "C" int  zfish_search_probcut_beta(int beta, unsigned char improving);
extern "C" int  zfish_search_probcut_beta_deep(int beta);
extern "C" int  zfish_search_null_move_threshold(int beta, int depth, unsigned char improving);
extern "C" int  zfish_search_null_move_reduction(int depth);
extern "C" int  zfish_search_nmp_min_ply(int ply, int depth, int r);
extern "C" int  zfish_search_futility_margin(int depth, unsigned char tt_hit,
                                             unsigned char improving,
                                             unsigned char opponent_worsening,
                                             int correction_value);
extern "C" int  zfish_search_futility_return(int beta, int eval);
extern "C" int  zfish_search_quiet_low_ply_scale(int bonus);
extern "C" int  zfish_search_quiet_cont_scale(int bonus);
extern "C" int  zfish_search_quiet_pawn_scale(int bonus);

#define ZFISH_SEARCH_BRIDGE_SKIP_TO_CORRECTED_STATIC_EVAL
#define ZFISH_SEARCH_BRIDGE_SKIP_VALUE_DRAW
#define ZFISH_SEARCH_BRIDGE_SKIP_REDUCTION
#define ZFISH_SEARCH_BRIDGE_SKIP_VALUE_TO_TT
#define ZFISH_SEARCH_BRIDGE_SKIP_VALUE_FROM_TT
#define ZFISH_SEARCH_BRIDGE_SKIP_CLEAR
#define ZFISH_SEARCH_BRIDGE_SKIP_ENSURE_NET
#define ZFISH_SEARCH_BRIDGE_SKIP_EXTRACT_PONDER
#define ZFISH_SEARCH_BRIDGE_SKIP_WORKER_CTOR
#define ZFISH_SEARCH_BRIDGE_SKIP_PV
#define ZFISH_SEARCH_BRIDGE_SKIP_START_SEARCHING
#define ZFISH_SEARCH_BRIDGE_SKIP_ITERDEEP_FN
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_REDUCTIONS_FILL
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_STAT_BONUS_MALUS
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_CORRECTION_VALUE
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_CONTHIST_DELTA
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_QUIET_SCALES
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_RAZOR_MARGIN
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_FUTILITY
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_NULLMOVE
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_PROBCUT
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_MOVECOUNT
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_CAPTURE_PRUNE
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_QUIET_PRUNE
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_SINGULAR
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_LMR_ADJUST
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_POST_BONUS
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_IS_SHUFFLING
#define ZFISH_SEARCH_BRIDGE_SKIP_UPDATE_CONTHIST
#define ZFISH_SEARCH_BRIDGE_SKIP_UPDATE_QUIET
#define ZFISH_SEARCH_BRIDGE_SKIP_UPDATE_ALL_STATS
#define ZFISH_SEARCH_BRIDGE_SKIP_UPDATE_CORRECTION_HISTORY
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_QSEARCH_STAND_PAT
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_QSEARCH_FAIL_HIGH
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_EVAL_DIFF
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_QSEARCH_FUTILITY_BASE
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_PRIOR_HIST_SCALE
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_STAT_SCORE
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_CORRHIST_BONUS
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_ASPIRATION
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_OPTIMISM
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_AGE_MAIN_HISTORY
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_FILL_LOW_PLY
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_CLEAR_HIST
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_SET_CONT_HIST
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_QSEARCH
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_SEARCH
#define ZFISH_SEARCH_BRIDGE_USE_ZIG_ITERDEEP
// The Zig runtime owns the engine; src/search.cpp is no longer compiled into the
// default build. Supply the headers, namespace visibility, the SearchedList
// alias, and the dead (no-tablebase) syzygy_extend_pv stub that the bridge code
// below previously got from the included translation unit.
#include "search.h"
#include "movepick.h"
using namespace Stockfish;
using namespace Stockfish::Search;

namespace Stockfish {
inline constexpr int SEARCHEDLIST_CAPACITY = 32;
using SearchedList                         = ValueList<Move, SEARCHEDLIST_CAPACITY>;
namespace {
// rootInTB is always false in this no-tablebase build, so pv() never calls this.
void syzygy_extend_pv(const OptionsMap&, const Search::LimitsType&, Position&, Search::RootMove&,
                      Value&) {}
}  // namespace
}  // namespace Stockfish

// Layout proof for zig_build/board/position.zig's WorkerHistories mirror. The
// per-Worker history tables form a contiguous int16-array prefix of the Worker
// (no vtable; mainHistory at offset 0), so ported Zig search code can address
// every table from a single Worker pointer. offsetof is not constexpr-valid on
// the non-standard-layout Worker, so we pin each table's *footprint* here
// instead: with no padding possible between int16 arrays, matching sizes plus
// the proven mainHistory@0 origin fix every table offset, and the signature
// gate confirms it end to end. A resized upstream table fails the build here.
static_assert(sizeof(Stockfish::ButterflyHistory) == 2 * 65536 * 2);
static_assert(sizeof(Stockfish::LowPlyHistory) == 5 * 65536 * 2);
static_assert(sizeof(Stockfish::CapturePieceToHistory) == 16 * 64 * 8 * 2);
static_assert(sizeof(Stockfish::ContinuationHistory) == 16 * 64 * 16 * 64 * 2);
static_assert(sizeof(Stockfish::ContinuationHistory[2][2]) == 2 * 2 * 16 * 64 * 16 * 64 * 2);
static_assert(sizeof(Stockfish::CorrectionHistory<Stockfish::Continuation>)
              == 16 * 64 * 16 * 64 * 2);
static_assert(sizeof(Stockfish::TTMoveHistory) == 2);

// Layout proof for the SharedHistories mirror (reached via Worker.sharedHistory).
// Each DynStats is { size_t size; T* data } = 16 bytes (the LargePagePtr deleter
// is stateless, so the unique_ptr is one pointer), then the two index masks.
static_assert(sizeof(Stockfish::SharedHistories) == 48);
static_assert(sizeof(Stockfish::UnifiedCorrectionHistory) == 16);
static_assert(sizeof(Stockfish::PawnHistory) == 16);
static_assert(sizeof(Stockfish::StateInfo) == 192);
static_assert(sizeof(Stockfish::Search::PVMoves) == 504);  // [247]Move padded + size_t

// tt_context hands Zig the live TT cluster array, cluster count, and generation so
// it can call the Zig-native tt.probe/save directly.
// (do_move/undo_move/evaluate are now inlined in the Zig search: the accumulator
// stack push/pop are Zig-owned, pos.do_move routes to the Zig make-move, and the
// NNUE forward pass + eval scaling are Zig too. So the Zig search counts the node,
// pushes/pops the accumulator slot, sets the continuation history, and runs the
// network eval itself. worker_state hands it the stable per-search pointers it
// needs once per entry: the accumulator stack, the node counter, the numa-resolved
// Network, the accumulator-refresh cache, and the optimism[COLOR_NB] array.)
// check_time inputs handed to the Zig search once per search tree. Layout matches
// the Zig SearchTimeState extern struct exactly.
struct ZfishSearchTimeState {
    int*                 calls_cnt;            // null => not the main thread
    std::uint8_t*        stop_write;
    const std::uint8_t*  ponder;
    const std::uint8_t*  stop_on_ponderhit;
    std::int64_t         tm_start_time;
    std::int64_t         tm_maximum_time;
    std::uint64_t        lim_nodes;
    std::int64_t         lim_movetime;
    std::uint8_t         tm_use_nodes_time;
    std::uint8_t         use_time_management;
};

// C++ steady_clock now() in milliseconds, so the Zig check_time computes elapsed
// in the same epoch as the C++-sampled startTime.
extern "C" std::int64_t zfish_now() { return Stockfish::now(); }

// iterative_deepening() state snapshot. Layout matches the Zig ZfishIdState
// extern struct exactly. Filled once at entry on the skill-off path.
struct ZfishIdState {
    void*               root_pos;
    void*               root_moves;
    std::size_t*        pv_idx;
    std::size_t*        pv_last;
    int*                sel_depth;
    int*                root_depth;
    int*                root_delta;
    int*                optimism;
    const std::uint64_t* nodes;
    std::uint8_t*       stop;
    std::uint8_t*       increase_depth;
    std::uint8_t*       stop_on_ponderhit;
    const std::uint8_t* ponder;
    int*                iter_value;
    double*             previous_time_reduction;
    void*               last_iter_pv;
    std::size_t         root_moves_count;
    std::size_t         thread_idx;
    std::size_t         threads_size;
    std::size_t         multipv_option;
    std::int64_t        tm_optimum;
    std::int64_t        tm_maximum;
    std::int64_t        tm_start_time;
    int                 limits_depth;
    int                 limits_mate;
    int                 best_previous_score;
    int                 best_previous_average_score;
    double              skill_level;
    std::uint8_t        is_main;
    std::uint8_t        use_time_management;
    std::uint8_t        tm_use_nodes_time;
    std::uint8_t        skill_enabled;
};

extern "C" void zfish_search_id_state(void* worker, ZfishIdState* out) {
    using namespace Stockfish;
    auto* w           = static_cast<Search::Worker*>(worker);
    const bool isMain = w->is_mainthread();

    out->root_pos                = &w->rootPos;
    out->root_moves              = w->rootMoves.data();
    out->pv_idx                  = &w->pvIdx;
    out->pv_last                 = &w->pvLast;
    out->sel_depth               = &w->selDepth;
    out->root_depth              = &w->rootDepth;
    out->root_delta              = &w->rootDelta;
    out->optimism                = &w->optimism[0];
    out->nodes                   = reinterpret_cast<const std::uint64_t*>(&w->nodes);
    out->stop                    = reinterpret_cast<std::uint8_t*>(&w->threads.stop);
    out->increase_depth          = reinterpret_cast<std::uint8_t*>(&w->threads.increaseDepth);
    out->ponder                  = nullptr;
    out->last_iter_pv            = &w->lastIterationPV;
    out->root_moves_count        = w->rootMoves.size();
    out->thread_idx              = w->threadIdx;
    out->threads_size            = w->threads.size();
    out->limits_depth            = w->limits.depth;
    out->limits_mate             = w->limits.mate;
    out->use_time_management     = w->limits.use_time_management() ? 1 : 0;
    out->is_main                 = isMain ? 1 : 0;

    Skill skill(w->options["Skill Level"],
                w->options["UCI_LimitStrength"] ? int(w->options["UCI_Elo"]) : 0);
    out->skill_enabled = skill.enabled() ? 1 : 0;
    out->skill_level   = skill.level;

    if (isMain)
    {
        auto* m                       = w->main_manager();
        out->stop_on_ponderhit        = reinterpret_cast<std::uint8_t*>(&m->stopOnPonderhit);
        out->ponder                   = reinterpret_cast<const std::uint8_t*>(&m->ponder);
        out->iter_value               = reinterpret_cast<int*>(m->iterValue.data());
        out->previous_time_reduction  = &m->previousTimeReduction;
        out->tm_optimum               = m->tm.optimum();
        out->tm_maximum               = m->tm.maximum();
        out->tm_start_time            = m->tm.startTime;
        out->tm_use_nodes_time        = m->tm.useNodesTime ? 1 : 0;
        out->best_previous_score      = m->bestPreviousScore;
        out->best_previous_average_score = m->bestPreviousAverageScore;
        out->multipv_option           = std::size_t(w->options["MultiPV"]);
    }
    else
    {
        out->stop_on_ponderhit       = nullptr;
        out->ponder                  = nullptr;
        out->iter_value              = nullptr;
        out->previous_time_reduction = nullptr;
        out->tm_optimum              = 0;
        out->tm_maximum              = 0;
        out->tm_start_time           = 0;
        out->tm_use_nodes_time       = 0;
        out->best_previous_score     = 0;
        out->best_previous_average_score = 0;
        out->multipv_option          = std::size_t(w->options["MultiPV"]);
    }
}

// UCI pv() sink (output only -- not parity-observable).
extern "C" void zfish_search_id_pv(void* worker, int depth) {
    auto* w = static_cast<Stockfish::Search::Worker*>(worker);
    w->main_manager()->pv(*w, w->threads, w->tt, depth);
}

// Cross-thread bestMoveChanges collection: sum and reset, returned as a double
// (keeps the multi-thread result correct from one extern).
extern "C" double zfish_search_id_collect_bmc(void* worker) {
    auto*  w   = static_cast<Stockfish::Search::Worker*>(worker);
    double tot = 0;
    for (auto&& th : w->threads)
    {
        tot += th->worker->bestMoveChanges;
        th->worker->bestMoveChanges = 0;
    }
    return tot;
}

extern "C" void zfish_search_cb_worker_state(void* worker, void** out_acc_stack,
                                             std::uint64_t** out_nodes, const void** out_network,
                                             void** out_cache, const void** out_optimism,
                                             int** out_nmp_min_ply, int** out_sel_depth,
                                             int** out_root_depth, const int** out_reductions,
                                             const int** out_root_delta,
                                             const void** out_last_iter_pv,
                                             const std::uint8_t** out_stop,
                                             const std::size_t** out_pv_idx,
                                             void** out_root_moves,
                                             const std::size_t** out_pv_last,
                                             std::uint64_t** out_best_move_changes,
                                             ZfishSearchTimeState* out_time) {
    auto* w           = static_cast<Stockfish::Search::Worker*>(worker);
    *out_acc_stack    = &w->accumulatorStack;
    *out_nodes        = reinterpret_cast<std::uint64_t*>(&w->nodes);
    *out_network      = &w->network[w->numaAccessToken];
    *out_cache        = &w->refreshTable;
    *out_optimism     = &w->optimism[0];
    *out_nmp_min_ply  = &w->nmpMinPly;
    *out_sel_depth    = &w->selDepth;
    *out_root_depth   = &w->rootDepth;
    *out_reductions   = w->reductions.data();
    *out_root_delta   = &w->rootDelta;
    *out_last_iter_pv = &w->lastIterationPV;
    *out_stop         = reinterpret_cast<const std::uint8_t*>(&w->threads.stop);
    *out_pv_idx       = &w->pvIdx;
    *out_root_moves   = w->rootMoves.data();
    *out_pv_last      = &w->pvLast;
    *out_best_move_changes = reinterpret_cast<std::uint64_t*>(&w->bestMoveChanges);

    if (w->is_mainthread())
    {
        auto* m                      = w->main_manager();
        out_time->calls_cnt          = &m->callsCnt;
        out_time->stop_write         = reinterpret_cast<std::uint8_t*>(&w->threads.stop);
        out_time->ponder             = reinterpret_cast<const std::uint8_t*>(&m->ponder);
        out_time->stop_on_ponderhit  = reinterpret_cast<const std::uint8_t*>(&m->stopOnPonderhit);
        out_time->tm_start_time      = m->tm.startTime;
        out_time->tm_maximum_time    = m->tm.maximumTime;
        out_time->lim_nodes          = w->limits.nodes;
        out_time->lim_movetime       = w->limits.movetime;
        out_time->tm_use_nodes_time  = m->tm.useNodesTime ? 1 : 0;
        out_time->use_time_management = w->limits.use_time_management() ? 1 : 0;
    }
    else
        out_time->calls_cnt = nullptr;
}

extern "C" void zfish_search_cb_tt_context(void* worker, void** out_table,
                                           std::size_t* out_cluster_count,
                                           std::uint8_t* out_generation) {
    auto& tt          = static_cast<Stockfish::Search::Worker*>(worker)->tt;
    *out_table        = tt.table;
    *out_cluster_count = tt.clusterCount;
    *out_generation   = tt.generation8;
}

// (zfish_search_cb_nodes retired: the Zig search reads the node counter through
// the stable pointer worker_state hands it, the same address this relaxed load
// targeted -- bit-identical in the single-threaded bench/parity runs.)

// Additional callbacks for the ported Zig search() (non-root). The rest expose
// Worker/threads state the non-root search reads.
// (pos_do_move/pos_undo_move retired: the qsearch TT-move cutoff verification
// now calls the Zig-owned Position make/unmake directly -- it computes
// gives_check in Zig and passes throwaway DirtyPiece/DirtyThreats scratch, since
// no accumulator slot is pushed for the verification peek.)
// (do_null_move/undo_null_move are now inlined in the Zig search: null moves
// touch no accumulator, so the Zig search calls the Zig-owned pos.do_null_move /
// undo_null_move and sets the continuation-history pointer directly.)

// (Worker::reduction is now inlined in the Zig search: the formula reads the
// per-thread reductions[] table and rootDelta, both handed to Zig as stable
// pointers by worker_state.)

// (zfish_search_cb_check_time retired: worker_state snapshots the SearchManager
// time state (callsCnt, tm fields, limits, ponder, stopOnPonderhit, writable
// stop) into SearchTimeState on the main thread, and the Zig search runs the
// decision itself -- only zfish_now() (a steady_clock syscall) stays in C++.
// The dead dbg_print / lastInfoTime block is dropped.)

// (zfish_search_cb_in_last_iter_pv retired: lastIterationPV is an inline PVMoves
// member, so worker_state hands Zig a stable pointer to it and the follow-pv
// test compares against it directly.)

// (nmpMinPly get/set, selDepth update, and rootDepth read are now done in Zig
// through the stable scalar pointers worker_state hands it -- single-threaded
// bench/parity, so the same-address reads/writes are bit-identical.)

// (zfish_search_cb_stop retired: worker_state hands Zig a pointer to the shared
// threads.stop std::atomic_bool, and the Zig search runs the relaxed load
// itself -- bit-identical to this load(memory_order_relaxed).)

// Root-node callbacks for the ported Zig search<Root>. rootMoves is a
// std::vector<RootMove> (each with its own std::vector<Move> pv), so it stays a
// C++-owned structure the Zig search reaches only through these.
// (zfish_search_cb_root_tt_move / zfish_search_cb_root_in_list retired: RootMove
// is a standard-layout POD, so worker_state hands Zig the rootMoves array base
// and pvLast, and the Zig search<Root> reads pv[0] / scans [pvIdx, pvLast)
// directly.)

// (zfish_search_cb_root_pvidx_nonzero retired: worker_state hands Zig a pointer
// to Worker::pvIdx and the singular-extension guard compares it directly.)

extern "C" void zfish_search_cb_root_on_iter(void* worker, int depth, std::uint16_t move,
                                             int move_count) {
    using namespace Stockfish;
    auto* w = static_cast<Search::Worker*>(worker);
    if (w->is_mainthread())
        w->main_manager()->updates.onIter(
          {depth, UCIEngine::move(Move(move), w->rootPos.is_chess960()),
           static_cast<std::size_t>(move_count) + w->pvIdx});
}

// (zfish_search_cb_root_update retired: the Zig search<Root> updates the RootMove
// entry directly through the rootMoves array base -- effort/averageScore/
// meanSquaredScore, the score/bound-flag/PV store on a PV move, and the
// bestMoveChanges atomic increment, all handed over by worker_state.)

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
    ZfishMoveSortEntry* moves;
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

struct ZfishPositionSnapshot {
    std::uint8_t side_to_move;
    std::uint64_t pieces_all;
    std::uint64_t pieces_by_color[2];
    std::uint64_t pieces_by_type[8];
    std::uint64_t blockers_for_king[2];
    std::uint64_t pinners[2];
    std::uint8_t king_square[2];
    std::uint8_t ep_square;
    std::uint8_t castling_rights;
    std::uint8_t castling_impeded[16];
    std::uint8_t castling_rook_square[16];
    std::uint64_t checkers;
    std::uint8_t board[64];
    std::uint64_t pawn_key;
    std::uint64_t key;
    int           material_value;
    int           rule50_count;
    int           game_ply;
    std::uint8_t  is_chess960;
};

struct ZfishMovepickHistorySnapshot {
    const void* main_base;
    const void* low_ply_base;
    const void* capture_base;
    const void* continuation_base[6];
    const void* pawn_table;
    std::uint64_t pawn_mask;
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

struct ZfishTtProbeTableOutput {
    std::uint8_t      found;
    void*             writer_ptr;
    ZfishTtReadOutput data;
};

struct ZfishBitboardMagicInitEntry {
    std::uint64_t mask;
    std::uint64_t magic;
    unsigned      shift;
    std::size_t   attack_offset;
};

static_assert(sizeof(Stockfish::StatsEntry<std::int16_t, 7183>) == sizeof(std::int16_t));
static_assert(alignof(Stockfish::StatsEntry<std::int16_t, 7183>) == alignof(std::int16_t));
static_assert(sizeof(Stockfish::StatsEntry<std::int16_t, 8192, true>)
            == sizeof(std::int16_t));
static_assert(alignof(Stockfish::StatsEntry<std::int16_t, 8192, true>)
            == alignof(std::int16_t));
static_assert(std::atomic<std::int16_t>::is_always_lock_free);

int zfish_search_to_corrected_static_eval(int v, int cv);
int zfish_search_value_draw(std::size_t nodes);
int zfish_search_value_to_tt(int v, int ply);
int zfish_search_value_from_tt(int v, int ply, int r50c);
int zfish_search_reduction(const int* reductions,
                           int        depth,
                           int        move_number,
                           int        delta,
                           int        root_delta,
                           std::uint8_t improving);
ZfishTimemanOutput zfish_timeman_init(ZfishTimemanInput input);
void zfish_movepick_partial_insertion_sort(ZfishMoveSortEntry* entries,
                                           std::size_t         count,
                                           int                 limit);
int zfish_movepick_init_main_stage(std::uint8_t has_checkers,
                                   std::uint8_t has_tt_move,
                                   int          depth);
int zfish_movepick_init_probcut_stage(std::uint8_t has_tt_move);
std::size_t zfish_movepick_score_list(std::uint8_t                 kind,
                                      const ZfishMovePickerContext* context,
                                      ZfishMoveSortEntry*           outputs);
std::uint16_t zfish_movepick_next_move(ZfishMovePickerState*         state,
                                       const ZfishMovePickerContext* context);
int zfish_eval_compute_value(ZfishEvalInput input);
std::size_t zfish_movegen_generate_captures(const void* pos, std::uint16_t* move_list);
std::size_t zfish_movegen_generate_quiets(const void* pos, std::uint16_t* move_list);
std::size_t zfish_movegen_generate_evasions(const void* pos, std::uint16_t* move_list);
std::size_t zfish_movegen_generate_non_evasions(const void* pos, std::uint16_t* move_list);
std::size_t zfish_movegen_generate_legal(const void* pos, std::uint16_t* move_list);
std::uint8_t zfish_position_move_is_legal(const void* pos_ptr, std::uint16_t raw_move);
void zfish_movepick_fill_history_snapshot(const void*                     main_history_ptr,
                                          const void*                     low_ply_history_ptr,
                                          const void*                     capture_history_ptr,
                                          const void*                     continuation_history_ptr,
                                          const void*                     shared_history_ptr,
                                          ZfishMovepickHistorySnapshot* out);
int zfish_movepick_pawn_history_value(const void* shared_history_ptr,
                                      std::uint64_t pawn_mask,
                                      std::uint64_t pawn_key,
                                      std::uint8_t  piece,
                                      std::uint8_t  square);
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
ZfishTtProbeTableOutput zfish_tt_probe_table(void*         table,
                                             std::size_t   cluster_count,
                                             std::uint64_t key,
                                             std::uint8_t  generation,
                                             int           depth_none);
void zfish_tt_resize_state(void**        table_ptr,
                           std::size_t*  cluster_count_ptr,
                           std::uint8_t* generation_ptr,
                           std::size_t   mb,
                           void*         threads_ptr);
void zfish_tt_clear_state(void*          table_ptr,
                          std::size_t    cluster_count,
                          std::uint8_t*  generation_ptr,
                          void*          threads_ptr);

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
    std::uint16_t reserved;
    int           tb_rank;
    int           tb_score;
};

using ZfishOpaqueCallback = void (*)(void*);

std::size_t zfish_thread_next_power_of_two(std::uint64_t count);
std::size_t zfish_thread_pick_best_thread(const ZfishThreadSummary* summaries,
                                          std::size_t               count);
void zfish_threadpool_reconfigure(void*       pool,
                                  const void* numa_config,
                                  const void* shared_state,
                                  const void* update_context);
void zfish_thread_run_callback(void* thread_ptr, ZfishOpaqueCallback callback, void* context);
void zfish_threadpool_clear(void* pool);
void zfish_threadpool_ensure_network_replicated(void* pool);
std::uint64_t zfish_threadpool_nodes_searched(void* pool);
std::uint64_t zfish_threadpool_tb_hits(void* pool);
void zfish_threadpool_reset_for_reconfigure(void* pool);
void zfish_threadpool_bound_nodes_assign(void* pool, const std::size_t* nodes, std::size_t count);
std::size_t zfish_shared_state_threads_value(const void* shared_state);
std::uint8_t zfish_shared_state_numa_policy_mode(const void* shared_state);
void zfish_shared_state_clear_histories(const void* shared_state);
void zfish_shared_state_insert_history(const void*  shared_state,
                                       const void*  numa_config,
                                       std::size_t  numa_index,
                                       std::size_t  size,
                                       std::uint8_t do_bind);
std::uint8_t zfish_numa_config_suggests_binding_threads(const void* numa_config,
                                                        std::size_t requested);
std::size_t zfish_numa_config_distribute_threads_among_nodes(const void* numa_config,
                                                             std::size_t requested,
                                                             std::size_t* out_nodes);
std::size_t zfish_numa_config_node_count(const void* numa_config);
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

void update_continuation_histories(Stack* ss, Piece pc, Square to, int bonus) {
    zfish_search_update_continuation_histories(ss, static_cast<std::uint8_t>(pc),
                                               static_cast<std::uint8_t>(to), bonus);
}

void update_quiet_histories(
  const Position& pos, Stack* ss, Search::Worker& workerThread, Move move, int bonus) {
    zfish_search_update_quiet_histories(&workerThread, &pos, ss, move.raw(), bonus);
}

void update_all_stats(const Position& pos,
                      Stack*          ss,
                      Search::Worker& workerThread,
                      Move            bestMove,
                      Square          prevSq,
                      SearchedList&   quietsSearched,
                      SearchedList&   capturesSearched,
                      Depth           depth,
                      Move            ttMove) {
    zfish_search_update_all_stats(
      &workerThread, const_cast<Position*>(&pos), ss, bestMove.raw(), static_cast<int>(prevSq),
      reinterpret_cast<const std::uint16_t*>(quietsSearched.begin()), quietsSearched.size(),
      reinterpret_cast<const std::uint16_t*>(capturesSearched.begin()), capturesSearched.size(),
      depth, ttMove.raw());
}

void update_correction_history(const Position& pos,
                               Stack* const    ss,
                               Search::Worker& workerThread,
                               const int       bonus) {
    zfish_search_update_correction_history(&workerThread, &pos, ss, bonus);
}

Value value_to_tt(Value v, int ply) { return Value(zfish_search_value_to_tt(v, ply)); }

Value value_from_tt(Value v, int ply, int r50c) {
    return Value(zfish_search_value_from_tt(v, ply, r50c));
}

}  // namespace

int Search::Worker::reduction(bool i, Depth d, int mn, int delta) const {
    return zfish_search_reduction(reductions.data(), d, mn, delta, rootDelta, std::uint8_t(i));
}

// Worker::clear runs the four Zig-owned resets: per-worker histories, the shared
// correction/pawn history, the reductions table, and the NNUE refresh cache.
void Search::Worker::clear() {
    zfish_search_clear_worker_histories(this);
    zfish_search_clear_shared_history(&sharedHistory, numaThreadIdx, numaTotal);
    zfish_search_fill_reductions(reductions.data(), reductions.size());
    zfish_search_clear_refresh_cache(&refreshTable,
                                     network[numaAccessToken].featureTransformer.biases.data());
}

void Search::Worker::ensure_network_replicated() {
    (void) (network[numaAccessToken]);  // force lazy numa initialization off the search path
}

bool Search::RootMove::extract_ponder_from_tt(const TranspositionTable& tt, Position& pos) {
    return bool(zfish_search_extract_ponder_from_tt(&pv, tt.table, tt.clusterCount,
                                                    tt.generation8, &pos));
}

// Worker constructor relocated verbatim from search.cpp: unpack the SharedState
// into members and run the initial clear().
Search::Worker::Worker(Search::SharedState&            sharedState,
                       std::unique_ptr<Search::ISearchManager> sm,
                       std::size_t                     threadId,
                       std::size_t                     numaThreadId,
                       std::size_t                     numaTotalThreads,
                       NumaReplicatedAccessToken       token) :
    sharedHistory(sharedState.sharedHistories.at(token.get_numa_index())),
    threadIdx(threadId),
    numaThreadIdx(numaThreadId),
    numaTotal(numaTotalThreads),
    numaAccessToken(token),
    manager(std::move(sm)),
    options(sharedState.options),
    threads(sharedState.threads),
    tt(sharedState.tt),
    network(sharedState.network),
    refreshTable(network[token]) {
    clear();
}

// SearchManager::pv (UCI info output) relocated verbatim from search.cpp. The
// syzygy_extend_pv call is dead in this no-tablebase build (rootInTB is always
// false, so v never lands in the decisive-non-mate TB range that triggers it);
// the symbol is provided once the search.cpp include is dropped.
void Search::SearchManager::pv(Search::Worker&           worker,
                               const ThreadPool&         threads,
                               const TranspositionTable& tt,
                               Depth                     depth) {
    const auto nodes     = threads.nodes_searched();
    auto&      rootMoves = worker.rootMoves;
    auto&      pos       = worker.rootPos;
    std::size_t multiPV  = std::min(std::size_t(worker.options["MultiPV"]), rootMoves.size());
    std::uint64_t tbHits = threads.tb_hits() + (worker.tbConfig.rootInTB ? rootMoves.size() : 0);

    for (std::size_t i = 0; i < multiPV; ++i)
    {
        bool usePreviousScore = rootMoves[i].score == -VALUE_INFINITE;

        if (depth == 1 && usePreviousScore && i > 0)
            continue;

        Depth d = usePreviousScore ? std::max(1, depth - 1) : depth;
        Value v = usePreviousScore ? rootMoves[i].previousScore : rootMoves[i].uciScore;

        if (v == -VALUE_INFINITE)
            v = VALUE_ZERO;

        bool isTBScore = worker.tbConfig.rootInTB && !is_mate_or_mated(v);
        v              = isTBScore ? rootMoves[i].tbScore : v;

        if (is_decisive(v) && !is_mate_or_mated(v) && (!rootMoves[i].score_is_bound() || isTBScore))
            syzygy_extend_pv(worker.options, worker.limits, pos, rootMoves[i], v);

        std::string pv;
        for (Move m : rootMoves[i].pv)
            pv += UCIEngine::move(m, pos.is_chess960()) + " ";

        if (!pv.empty())
            pv.pop_back();

        auto wdl   = worker.options["UCI_ShowWDL"] ? UCIEngine::wdl(v, pos) : "";
        auto bound = rootMoves[i].scoreLowerbound
                     ? "lowerbound"
                     : (rootMoves[i].scoreUpperbound ? "upperbound" : "");

        InfoFull info;
        info.depth    = d;
        info.selDepth = rootMoves[i].selDepth;
        info.multiPV  = i + 1;
        info.score    = {v, pos};
        info.wdl      = wdl;

        if (!(isTBScore || usePreviousScore))
            info.bound = bound;

        TimePoint time = std::max(TimePoint(1), tm.elapsed_time());
        info.timeMs    = time;
        info.nodes     = nodes;
        info.nps       = nodes * 1000 / time;
        info.tbHits    = tbHits;
        info.pv        = pv;
        info.hashfull  = tt.hashfull();

        updates.onUpdateFull(info);
    }
}

bool Search::Worker::iterative_deepening() { return bool(zfish_search_iterative_deepening(this)); }

// SearchManager::check_time relocated verbatim from search.cpp. The Zig search
// runs the per-node time check itself, so this is unused on the search path, but
// it is SearchManager's only virtual override and therefore anchors the class
// vtable in this translation unit.
void Search::SearchManager::check_time(Search::Worker& worker) {
    if (--callsCnt > 0)
        return;

    callsCnt = worker.limits.nodes ? std::min(512, int(worker.limits.nodes / 1024)) : 512;

    static TimePoint lastInfoTime = now();

    TimePoint elapsed = tm.elapsed([&worker]() { return worker.threads.nodes_searched(); });
    TimePoint tick    = worker.limits.startTime + elapsed;

    if (tick - lastInfoTime >= 1000)
    {
        lastInfoTime = tick;
        dbg_print();
    }

    if (ponder)
        return;

    if ((worker.limits.use_time_management() && (elapsed > tm.maximum() || stopOnPonderhit))
        || (worker.limits.movetime && elapsed >= worker.limits.movetime)
        || (worker.limits.nodes && worker.threads.nodes_searched() >= worker.limits.nodes))
        worker.threads.stop = true;
}

// Worker::start_searching relocated verbatim from search.cpp: the search entry
// (history/accumulator reset, time-management init, the iterative-deepening
// driver, the ponder wait, best-thread selection, and the bestmove output).
void Search::Worker::start_searching() {

    accumulatorStack.reset();
    lastIterationPV.clear();

    if (!is_mainthread())
    {
        iterative_deepening();
        return;
    }

    main_manager()->tm.init(limits, rootPos.side_to_move(), rootPos.game_ply(), options,
                            main_manager()->originalTimeAdjust);
    tt.new_search();

    if (rootMoves.empty())
    {
        main_manager()->updates.onUpdateNoMoves(
          {0, {rootPos.checkers() ? -VALUE_MATE : VALUE_DRAW, rootPos}});
        main_manager()->updates.onBestmove(UCIEngine::move(Move::none()), "");
        return;
    }

    threads.start_searching();
    bool uciPvSent = iterative_deepening();

    while (!threads.stop && (main_manager()->ponder || limits.infinite))
    {}  // Busy wait for a stop or a ponder reset

    threads.stop = true;

    threads.wait_for_search_finished();

    if (limits.npmsec)
        main_manager()->tm.advance_nodes_time(threads.nodes_searched()
                                              - limits.inc[rootPos.side_to_move()]);

    Worker* bestThread = this;
    Skill   skill =
      Skill(options["Skill Level"], options["UCI_LimitStrength"] ? int(options["UCI_Elo"]) : 0);

    if (!limits.depth && !skill.enabled())
        bestThread = threads.get_best_thread()->worker.get();

    main_manager()->bestPreviousScore        = bestThread->rootMoves[0].score;
    main_manager()->bestPreviousAverageScore = bestThread->rootMoves[0].averageScore;

    if (bestThread->rootMoves[0].pv.size() == 1
        && bestThread->rootMoves[0].extract_ponder_from_tt(tt, rootPos))
        uciPvSent = false;

    if (!uciPvSent || bestThread != this)
        main_manager()->pv(*bestThread, threads, tt, bestThread->rootDepth);

    std::string ponder;
    if (bestThread->rootMoves[0].pv.size() > 1)
        ponder = UCIEngine::move(bestThread->rootMoves[0].pv[1], rootPos.is_chess960());

    auto bestmove = UCIEngine::move(bestThread->rootMoves[0].pv[0], rootPos.is_chess960());
    main_manager()->updates.onBestmove(bestmove, ponder);
}

static_assert(sizeof(Move) == sizeof(std::uint16_t));


extern "C" std::uint8_t zfish_position_has_repeated(const void* pos_ptr) {
    const auto& pos = *static_cast<const Position*>(pos_ptr);
    return static_cast<std::uint8_t>(pos.has_repeated() ? 1 : 0);
}

extern "C" std::uint8_t zfish_position_is_draw_ply_one(const void* pos_ptr) {
    const auto& pos = *static_cast<const Position*>(pos_ptr);
    return static_cast<std::uint8_t>(pos.is_draw(1) ? 1 : 0);
}

extern "C" std::uint8_t zfish_position_is_repetition_ply_one(const void* pos_ptr) {
    const auto& pos = *static_cast<const Position*>(pos_ptr);
    return static_cast<std::uint8_t>(pos.is_repetition(1) ? 1 : 0);
}

extern "C" std::uint8_t zfish_position_move_is_legal(const void* pos_ptr,
                                                      std::uint16_t raw_move) {
    const auto& pos = *static_cast<const Position*>(pos_ptr);
    return std::uint8_t(pos.legal(Move(raw_move)) ? 1 : 0);
}

extern "C" void zfish_movepick_fill_history_snapshot(const void* main_history_ptr,
                                                      const void* low_ply_history_ptr,
                                                      const void* capture_history_ptr,
                                                      const void* continuation_history_ptr,
                                                      const void* shared_history_ptr,
                                                      ZfishMovepickHistorySnapshot* out) {
    out->main_base =
      main_history_ptr ? static_cast<const ButterflyHistory*>(main_history_ptr)->data() : nullptr;
    out->low_ply_base =
      low_ply_history_ptr ? static_cast<const LowPlyHistory*>(low_ply_history_ptr)->data() : nullptr;
    out->capture_base = capture_history_ptr
                        ? static_cast<const CapturePieceToHistory*>(capture_history_ptr)->data()
                        : nullptr;

    for (std::size_t slot = 0; slot < 6; ++slot)
        out->continuation_base[slot] = nullptr;

    if (continuation_history_ptr)
    {
        const auto* continuation_history =
          static_cast<const PieceToHistory* const*>(continuation_history_ptr);
        for (std::size_t slot = 0; slot < 6; ++slot)
            out->continuation_base[slot] = continuation_history[slot]->data();
    }

    if (shared_history_ptr)
    {
        const auto* shared_history = static_cast<const SharedHistories*>(shared_history_ptr);
        out->pawn_table =
          shared_history->pawnHistory.get_size() ? shared_history->pawnHistory[0].data() : nullptr;
        out->pawn_mask = shared_history->pawnHistSizeMinus1;
    }
    else
    {
        out->pawn_table = nullptr;
        out->pawn_mask = 0;
    }
}

extern "C" int zfish_movepick_pawn_history_value(const void* pawn_table_ptr,
                                                   std::uint64_t pawn_mask,
                                                   std::uint64_t pawn_key,
                                                   std::uint8_t piece,
                                                   std::uint8_t square) {
    if (!pawn_table_ptr)
        return 0;

    using PawnHistoryRow = Stockfish::StatsEntry<std::int16_t, 8192, true>[64];
    const auto* rows = static_cast<const PawnHistoryRow*>(pawn_table_ptr);
    const std::size_t index = static_cast<std::size_t>(pawn_key & pawn_mask);
    const std::size_t row_index = index * PIECE_NB + piece;
    const auto& entry = rows[row_index][square];
    return entry;
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
    const auto count = zfish_movegen_generate_legal(&pos, reinterpret_cast<std::uint16_t*>(moveList));
    return moveList + count;
}

static constexpr int ClusterSize = 3;

struct TTEntry {
    TTData read() const {
        const auto output = zfish_tt_entry_read(reinterpret_cast<const ZfishTtEntry*>(this), DEPTH_NONE);
        return TTData{Move(output.move16), Value(output.value16), Value(output.eval16),
                      Depth(output.depth), Bound(output.bound), output.is_pv != 0};
    }

    bool is_occupied() const { return bool(depth8); }
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

struct Cluster {
    TTEntry entry[ClusterSize];
    char    padding[2];
};

static_assert(sizeof(Cluster) == 32, "Suboptimal Cluster size");

extern "C" std::size_t zfish_threadpool_num_threads(const void* threads_ptr) {
    return static_cast<const ThreadPool*>(threads_ptr)->num_threads();
}

extern "C" void zfish_threadpool_zero_tt_slice(void*        threads_ptr,
                                                 std::size_t thread_id,
                                                 void*       table_ptr,
                                                 std::size_t start_cluster,
                                                 std::size_t cluster_len) {
    if (cluster_len == 0 || !table_ptr)
        return;

    auto* threads = static_cast<ThreadPool*>(threads_ptr);
    auto* table = static_cast<Cluster*>(table_ptr);
    threads->run_on_thread(thread_id, [table, start_cluster, cluster_len]() {
        std::memset(&table[start_cluster], 0, cluster_len * sizeof(Cluster));
    });
}

extern "C" void zfish_threadpool_wait_thread(void* threads_ptr, std::size_t thread_id) {
    static_cast<ThreadPool*>(threads_ptr)->wait_on_thread(thread_id);
}

#ifndef ZFISH_LEGACY_CPP_TARGET

std::uint8_t TTEntry::relative_age(std::uint8_t curr_generation) const {
    return zfish_tt_entry_relative_age(reinterpret_cast<const ZfishTtEntry*>(this), curr_generation);
}

TTWriter::TTWriter(TTEntry* tte) :
    entry(tte) {}

void TTWriter::write(
  Key k, Value v, bool pv, Bound b, Depth d, Move m, Value ev, std::uint8_t curr_generation) {
    zfish_tt_entry_save(reinterpret_cast<ZfishTtEntry*>(entry),
                        static_cast<std::uint64_t>(k),
                        static_cast<int>(v),
                        pv ? 1 : 0,
                        static_cast<std::uint8_t>(b),
                        static_cast<int>(d),
                        DEPTH_NONE,
                        static_cast<std::uint16_t>(m.raw()),
                        static_cast<int>(ev),
                        curr_generation);
}

void TranspositionTable::resize(std::size_t mbSize, ThreadPool& threads) {
    zfish_tt_resize_state(reinterpret_cast<void**>(&table),
                          &clusterCount,
                          &generation8,
                          mbSize,
                          &threads);
}

void TranspositionTable::clear(ThreadPool& threads) {
    zfish_tt_clear_state(table, clusterCount, &generation8, &threads);
}

int TranspositionTable::hashfull(int maxAge) const {
    return zfish_tt_hashfull(reinterpret_cast<const ZfishTtCluster*>(table),
                             clusterCount,
                             generation8,
                             maxAge);
}

void TranspositionTable::new_search() {
    generation8 = zfish_tt_generation_next(generation8);
}

std::uint8_t TranspositionTable::generation() const {
    return generation8;
}

std::tuple<bool, TTData, TTWriter> TranspositionTable::probe(const Key key) const {
    const auto output = zfish_tt_probe_table(table,
                                             clusterCount,
                                             static_cast<std::uint64_t>(key),
                                             generation8,
                                             DEPTH_NONE);

    TTData data{Move(output.data.move16),
                Value(output.data.value16),
                Value(output.data.eval16),
                Depth(output.data.depth),
                Bound(output.data.bound),
                output.data.is_pv != 0};

    return {output.found != 0, data, TTWriter(static_cast<TTEntry*>(output.writer_ptr))};
}

TTEntry* TranspositionTable::first_entry(const Key key) const {
    const auto index = zfish_tt_first_entry_index(static_cast<std::uint64_t>(key), clusterCount);
    return &table[index].entry[0];
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

std::string Eval::trace(Position& pos, const Eval::NNUE::Network& network) {
    const char* rendered = zfish_engine_eval_trace(&pos, &network);
    if (!rendered)
        std::abort();

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
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

        stage = zfish_movepick_init_main_stage(std::uint8_t(pos.checkers() ? 1 : 0),
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
ExtMove* MovePicker::score(const MoveList<Type>&) {

        static_assert(Type == CAPTURES || Type == QUIETS || Type == EVASIONS, "Wrong type");

        const std::uint8_t kind = Type == CAPTURES ? std::uint8_t{0}
                                                                : Type == QUIETS ? std::uint8_t{1}
                                                                                                 : std::uint8_t{2};

        const ZfishMovePickerContext context = {
            .pos                  = &pos,
            .main_history         = mainHistory,
            .low_ply_history      = lowPlyHistory,
            .capture_history      = captureHistory,
            .continuation_history = continuationHistory,
            .shared_history       = sharedHistory,
            .ply                  = ply,
        };

        static_assert(sizeof(ExtMove) == sizeof(ZfishMoveSortEntry));
        static_assert(alignof(ExtMove) == alignof(ZfishMoveSortEntry));

        const std::size_t count =
            zfish_movepick_score_list(kind, &context, reinterpret_cast<ZfishMoveSortEntry*>(cur));

        return cur + count;
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
        state.moves            = reinterpret_cast<ZfishMoveSortEntry*>(moves);

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

        return result;
}

void MovePicker::skip_quiet_moves() { skipQuiets = true; }

namespace Tablebases {

int MaxCardinality = 0;

void init(const std::string&) {
    MaxCardinality = 0;
}

WDLScore probe_wdl(Position&, ProbeState* result) {
    if (result)
        *result = FAIL;
    return WDLDraw;
}

int probe_dtz(Position&, ProbeState* result) {
    if (result)
        *result = FAIL;
    return 0;
}

bool root_probe(Position&,
                Search::RootMoves&,
                bool,
                bool,
                const std::function<bool()>&) {
    return false;
}

bool root_probe_wdl(Position&, Search::RootMoves&, bool) {
    return false;
}

Config rank_root_moves(const OptionsMap&            options,
                       Position&,
                       Search::RootMoves&,
                       bool,
                       const std::function<bool()>&) {
    Config config;
    config.cardinality = int(options["SyzygyProbeLimit"]);
    config.rootInTB = false;
    config.useRule50 = bool(options["Syzygy50MoveRule"]);
    config.probeDepth = int(options["SyzygyProbeDepth"]);
    return config;
}

}  // namespace Tablebases

// Constructor launches the thread and waits until it goes to sleep in idle_loop().
// Note that 'searching' and 'exit' should be already set.
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
        // Use the binder to [maybe] bind the threads to a NUMA node before doing
        // the Worker allocation. Ideally we would also allocate the SearchManager
        // here, but that's minor.
        this->numaAccessToken = binder();
        this->worker          = make_unique_large_page<Search::Worker>(
          sharedState, std::move(sm), n, idxInNuma, totalNuma, this->numaAccessToken);
    });

    wait_for_search_finished();
}


// Destructor wakes up the thread in idle_loop() and waits for its termination.
// Thread should be already waiting.
Thread::~Thread() {

    assert(!searching);

    exit = true;
    start_searching();
    stdThread.join();
}

// Wakes up the thread that will start the search.
void Thread::start_searching() {
    assert(worker != nullptr);
    run_custom_job([this]() { worker->start_searching(); });
}

// Clears the histories for the thread worker (usually before a new game).
void Thread::clear_worker() {
    assert(worker != nullptr);
    run_custom_job([this]() { worker->clear(); });
}

// Blocks on the condition variable until the thread has finished searching.
void Thread::wait_for_search_finished() {

    std::unique_lock<std::mutex> lk(mutex);
    cv.wait(lk, [&] { return !searching; });
}

// Launching a function in the thread.
void Thread::run_custom_job(std::function<void()> f) {
    {
        std::unique_lock<std::mutex> lk(mutex);
        cv.wait(lk, [&] { return !searching; });
        jobFunc   = std::move(f);
        searching = true;
    }
    cv.notify_one();
}

void Thread::worker_set_limits(const Search::LimitsType& limits) {
    assert(worker != nullptr);
    worker->set_limits(limits);
}

void Thread::worker_reset_root_setup_state() {
    assert(worker != nullptr);
    worker->reset_root_setup_state();
}

void Thread::worker_set_root_moves(const Search::RootMoves& rootMoves) {
    assert(worker != nullptr);
    worker->set_root_moves(rootMoves);
}

void Thread::worker_set_root_position(std::string_view fen, bool chess960) {
    assert(worker != nullptr);
    worker->set_root_position(fen, chess960);
}

void Thread::worker_set_root_state(const StateInfo& setupState) {
    assert(worker != nullptr);
    worker->set_root_state(setupState);
}

void Thread::worker_set_tb_config(Tablebases::Config config) {
    assert(worker != nullptr);
    worker->set_tb_config(config);
}

uint64_t Thread::worker_nodes_searched() const {
    assert(worker != nullptr);
    return worker->nodes_searched();
}

uint64_t Thread::worker_tb_hits() const {
    assert(worker != nullptr);
    return worker->tb_hits();
}

void Thread::worker_fill_summary(std::uint16_t& pv0Raw,
                                 bool&          scoreIsBound,
                                 bool&          pvHasMoreThanTwo,
                                 int&           score,
                                 int&           rootDepth) const {
    assert(worker != nullptr);
    worker->fill_thread_summary(pv0Raw, scoreIsBound, pvHasMoreThanTwo, score, rootDepth);
}

void Thread::ensure_network_replicated() { worker->ensure_network_replicated(); }

// Thread gets parked here, blocked on the condition variable when the thread has no work to do.
void Thread::idle_loop() {
    while (true)
    {
        std::unique_lock<std::mutex> lk(mutex);
        searching = false;
        cv.notify_one();  // Wake up anyone waiting for search finished
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

static size_t next_power_of_two(uint64_t count) { return count > 1 ? (2ULL << msb(count - 1)) : 1; }

// Creates/destroys threads to match the requested number.
// Created and launched threads will immediately go to sleep in idle_loop().
// Upon resizing, threads are recreated to allow for binding if necessary.
void ThreadPool::set(const NumaConfig&                           numaConfig,
                     Search::SharedState                         sharedState,
                     const Search::SearchManager::UpdateContext& updateContext) {

    if (threads.size() > 0)  // destroy any existing thread(s)
    {
        main_thread()->wait_for_search_finished();

        threads.clear();

        boundThreadToNumaNode.clear();
    }

    const size_t requested = sharedState.options["Threads"];

    if (requested > 0)  // create new thread(s)
    {
        // Binding threads may be problematic when there's multiple NUMA nodes and
        // multiple Stockfish instances running. In particular, if each instance
        // runs a single thread then they would all be mapped to the first NUMA node.
        // This is undesirable, and so the default behaviour (i.e. when the user does not
        // change the NumaConfig UCI setting) is to not bind the threads to processors
        // unless we know for sure that we span NUMA nodes and replication is required.
        const std::string numaPolicy(sharedState.options["NumaPolicy"]);
        const bool        doBindThreads = [&]() {
            if (numaPolicy == "none")
                return false;

            if (numaPolicy == "auto")
                return numaConfig.suggests_binding_threads(requested);

            // numaPolicy == "system", or explicitly set by the user
            return true;
        }();

        std::map<NumaIndex, size_t> counts;
        boundThreadToNumaNode = doBindThreads
                                ? numaConfig.distribute_threads_among_numa_nodes(requested)
                                : std::vector<NumaIndex>{};

        if (boundThreadToNumaNode.empty())
            counts[0] = requested;  // Pretend all threads are part of numa node 0
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

                // When not binding threads we want to force all access to happen
                // from the same NUMA node, because in case of NUMA replicated memory
                // accesses we don't want to trash cache in case the threads get scheduled
                // on the same NUMA node.
                auto binder = doBindThreads ? OptionalThreadToNumaNodeBinder(numaConfig, numaId)
                                                       : OptionalThreadToNumaNodeBinder(numaId);

                threads.emplace_back(std::make_unique<Thread>(sharedState, std::move(manager),
                                                                         threadId, counts[numaId]++,
                                                                         threadsPerNode[numaId], binder));
            };

            // Ensure the worker thread inherits the intended NUMA affinity at creation.
            if (doBindThreads)
                numaConfig.execute_on_numa_node(numaId, create_thread);
            else
                create_thread();
        }

        clear();

        main_thread()->wait_for_search_finished();
    }
}


// Sets threadPool data to initial values.
void ThreadPool::clear() {
    if (threads.size() == 0)
        return;

    for (auto&& th : threads)
        th->clear_worker();

    for (auto&& th : threads)
        th->wait_for_search_finished();

    // These two affect the time taken on the first move of a game.
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

#ifdef ZFISH_ZIG_BUILD
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

using ZfishOpaqueCallback = void (*)(void*);

std::size_t zfish_threadpool_thread_count(const void* pool_ptr) {
    return static_cast<const ThreadPool*>(pool_ptr)->size();
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

void zfish_threadpool_main_manager_set_stop_on_ponderhit(void*       pool_ptr,
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

void zfish_thread_run_callback(void* thread_ptr, ZfishOpaqueCallback callback, void* context) {
    auto* thread = static_cast<Thread*>(thread_ptr);
    thread->run_custom_job([callback, context]() { callback(context); });
}

void zfish_thread_wait_for_search_finished(void* thread_ptr) {
    static_cast<Thread*>(thread_ptr)->wait_for_search_finished();
}

void zfish_thread_start_searching(void* thread_ptr) {
    static_cast<Thread*>(thread_ptr)->start_searching();
}

void zfish_thread_clear_worker(void* thread_ptr) {
    static_cast<Thread*>(thread_ptr)->clear_worker();
}

void zfish_thread_ensure_network_replicated(void* thread_ptr) {
    static_cast<Thread*>(thread_ptr)->ensure_network_replicated();
}

void zfish_thread_worker_set_limits(void* thread_ptr, const void* limits_ptr) {
    auto* thread = static_cast<Thread*>(thread_ptr);
    thread->worker_set_limits(*static_cast<const Search::LimitsType*>(limits_ptr));
}

void zfish_thread_worker_reset_root_setup_state(void* thread_ptr) {
    static_cast<Thread*>(thread_ptr)->worker_reset_root_setup_state();
}

void zfish_thread_worker_set_root_moves(void* thread_ptr, const void* root_moves_ptr) {
    auto* thread = static_cast<Thread*>(thread_ptr);
    thread->worker_set_root_moves(*static_cast<const Search::RootMoves*>(root_moves_ptr));
}

void zfish_thread_worker_set_root_position(void*                thread_ptr,
                                           const unsigned char* fen_ptr,
                                           std::size_t          fen_len,
                                           std::uint8_t         chess960) {
    auto* thread = static_cast<Thread*>(thread_ptr);
    const auto fen = std::string_view(reinterpret_cast<const char*>(fen_ptr), fen_len);
    thread->worker_set_root_position(fen, chess960 != 0);
}

void zfish_thread_worker_set_root_state(void* thread_ptr, const void* setup_state_ptr) {
    auto* thread = static_cast<Thread*>(thread_ptr);
    thread->worker_set_root_state(*static_cast<const StateInfo*>(setup_state_ptr));
}

void zfish_thread_worker_set_tb_config(void* thread_ptr, ZfishTbConfig config) {
    auto* thread = static_cast<Thread*>(thread_ptr);
    thread->worker_set_tb_config(Tablebases::Config{config.cardinality, config.root_in_tb != 0,
                                                     config.use_rule50 != 0,
                                                     Depth(config.probe_depth)});
}

std::uint64_t zfish_thread_nodes_searched(const void* thread_ptr) {
    return static_cast<const Thread*>(thread_ptr)->worker_nodes_searched();
}

std::uint64_t zfish_thread_tb_hits(const void* thread_ptr) {
    return static_cast<const Thread*>(thread_ptr)->worker_tb_hits();
}

void zfish_thread_fill_summary(const void* thread_ptr, ZfishThreadSummary* out) {
    auto score_is_bound = false;
    auto pv_has_more_than_two = false;
    static_cast<const Thread*>(thread_ptr)->worker_fill_summary(
      out->pv0_raw, score_is_bound, pv_has_more_than_two, out->score, out->root_depth);
    out->score_is_bound = score_is_bound ? std::uint8_t{1} : std::uint8_t{0};
    out->pv_has_more_than_two = pv_has_more_than_two ? std::uint8_t{1} : std::uint8_t{0};
}

void zfish_threadpool_main_manager_reset_best_previous_average_score(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->bestPreviousAverageScore = VALUE_INFINITE;
}

void zfish_threadpool_main_manager_reset_previous_time_reduction(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->previousTimeReduction = 0.85;
}

void zfish_threadpool_main_manager_reset_calls_count(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->callsCnt = 0;
}

void zfish_threadpool_main_manager_reset_best_previous_score(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->bestPreviousScore = VALUE_INFINITE;
}

void zfish_threadpool_main_manager_reset_original_time_adjust(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->originalTimeAdjust = -1;
}

void zfish_threadpool_main_manager_clear_timeman(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->tm.clear();
}

}  // extern "C"
#endif

#endif  // ZFISH_LEGACY_CPP_TARGET


extern "C" {



void zfish_engine_numa_set_from_string(void*                numa_context_ptr,
                                       const unsigned char* text_ptr,
                                       std::size_t          text_len) {
    auto& numa_context = *static_cast<NumaReplicationContext*>(numa_context_ptr);
    numa_context.set_numa_config(
      NumaConfig::from_string(std::string(reinterpret_cast<const char*>(text_ptr), text_len)));
}

std::size_t zfish_tbprobe_max_cardinality() {
    return static_cast<std::size_t>(Tablebases::MaxCardinality);
}

ZfishEngineTablebaseProbe zfish_tbprobe_probe_fen(const unsigned char* fen_ptr,
                                                  std::size_t          fen_len,
                                                  std::uint8_t         chess960) {
    StateInfo probe_state;
    Position  probe_pos;
    if (probe_pos.set(std::string(reinterpret_cast<const char*>(fen_ptr), fen_len),
                      chess960 != 0, &probe_state)
          .has_value())
        return {};

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

std::uint8_t zfish_tbprobe_has_wdl_file(const unsigned char* code_ptr, std::size_t code_len) {
    const std::string code(reinterpret_cast<const char*>(code_ptr), code_len);
    std::ifstream     file(code + ".rtbw");
    const bool        is_open = file.is_open();
    return static_cast<std::uint8_t>(is_open ? 1 : 0);
}

std::uint8_t zfish_tbprobe_has_dtz_file(const unsigned char* code_ptr, std::size_t code_len) {
    const std::string code(reinterpret_cast<const char*>(code_ptr), code_len);
    std::ifstream     file(code + ".rtbz");
    const bool        is_open = file.is_open();
    return static_cast<std::uint8_t>(is_open ? 1 : 0);
}

void zfish_engine_tablebases_init(const unsigned char* path_ptr, std::size_t path_len) {
    Tablebases::init(std::string(reinterpret_cast<const char*>(path_ptr), path_len));
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

}  // namespace Stockfish

namespace Stockfish {

std::string engine_version_info() {
    const char* rendered = zfish_misc_engine_version_info_text();
    if (!rendered)
        std::abort();
    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

std::string engine_info(bool to_uci) {
    const char* rendered = zfish_misc_engine_info_mode(to_uci ? 1 : 0);
    if (!rendered)
        std::abort();
    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

namespace {

char* alloc_c_string(const std::string& value) {
    auto* buffer = static_cast<char*>(std::malloc(value.size() + 1));
    if (!buffer)
        return nullptr;

    std::memcpy(buffer, value.c_str(), value.size() + 1);
    return buffer;
}

std::optional<std::string> take_optional_c_string(const char* rendered) {
    if (!rendered)
        return std::nullopt;

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

}  // namespace

extern "C" {
void        zfish_misc_dbg_hit_on(std::uint8_t cond, int slot);
void        zfish_misc_dbg_mean_of(std::int64_t value, int slot);
void        zfish_misc_dbg_stdev_of(std::int64_t value, int slot);
void        zfish_misc_dbg_extremes_of(std::int64_t value, int slot);
void        zfish_misc_dbg_correl_of(std::int64_t value1, std::int64_t value2, int slot);
void        zfish_misc_dbg_print();
void        zfish_misc_dbg_clear();
}

std::string compiler_info() {
    const char* rendered = zfish_misc_compiler_info_text();
    if (!rendered)
        std::abort();

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

std::unique_ptr<Eval::NNUE::Network> Engine::get_default_network() const {

    auto network_ = std::make_unique<NN::Network>(NN::EvalFile{EvalFileDefaultName, "None", ""});

    network_->load(binaryDirectory, "");

    return network_;
}

void dbg_hit_on(bool cond, int slot) {
    zfish_misc_dbg_hit_on(static_cast<std::uint8_t>(cond ? 1 : 0), slot);
}

void dbg_mean_of(int64_t value, int slot) {
    zfish_misc_dbg_mean_of(value, slot);
}

void dbg_stdev_of(int64_t value, int slot) {
    zfish_misc_dbg_stdev_of(value, slot);
}

void dbg_extremes_of(int64_t value, int slot) {
    zfish_misc_dbg_extremes_of(value, slot);
}

void dbg_correl_of(int64_t value1, int64_t value2, int slot) {
    zfish_misc_dbg_correl_of(value1, value2, slot);
}

void dbg_print() { zfish_misc_dbg_print(); }

void dbg_clear() { zfish_misc_dbg_clear(); }

void start_logger(const std::string& fname) { Logger::start(fname); }

std::ostream& operator<<(std::ostream& os, SyncCout sc) {
    static std::mutex m;

    if (sc == IO_LOCK)
        m.lock();

    if (sc == IO_UNLOCK)
        m.unlock();

    return os;
}

void sync_cout_start() { std::cout << IO_LOCK; }
void sync_cout_end() { std::cout << IO_UNLOCK; }

extern "C" {
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

extern "C" {
const char* zfish_engine_option_on_change(void*                engine_ptr,
                                          std::uint8_t         callback_kind,
                                          const unsigned char* value_ptr,
                                          std::size_t          value_len,
                                          int                  int_value);
}

namespace {

constexpr std::uint8_t kOptionCallbackNone          = 0;
constexpr std::uint8_t kOptionCallbackDebugLogFile  = 1;
constexpr std::uint8_t kOptionCallbackNumaPolicy    = 2;
constexpr std::uint8_t kOptionCallbackThreads       = 3;
constexpr std::uint8_t kOptionCallbackHash          = 4;
constexpr std::uint8_t kOptionCallbackClearHash     = 5;
constexpr std::uint8_t kOptionCallbackSyzygyPath    = 6;
constexpr std::uint8_t kOptionCallbackEvalFile      = 7;

constexpr std::uint8_t kOptionTypeString            = 0;
constexpr std::uint8_t kOptionTypeCheck             = 1;
constexpr std::uint8_t kOptionTypeSpin              = 2;
constexpr std::uint8_t kOptionTypeButton            = 3;

std::optional<std::string> relay_engine_option_callback(Engine*                 engine,
                                                        std::uint8_t            callback_kind,
                                                        std::string_view        value,
                                                        int                     int_value) {
    return take_optional_c_string(zfish_engine_option_on_change(
      engine, callback_kind, reinterpret_cast<const unsigned char*>(value.data()), value.size(),
      int_value));
}

Option::OnChange make_option_callback(
  Engine* engine, std::uint8_t option_kind, std::uint8_t callback_kind) {
    if (callback_kind == kOptionCallbackNone)
        return nullptr;

    return [engine, option_kind, callback_kind](const Option& option) -> std::optional<std::string> {
        switch (option_kind)
        {
        case kOptionTypeString:
            return relay_engine_option_callback(engine, callback_kind, std::string(option), 0);
        case kOptionTypeCheck:
        case kOptionTypeSpin: {
            const auto value = int(option);
            return relay_engine_option_callback(engine, callback_kind, std::to_string(value), value);
        }
        case kOptionTypeButton:
            return relay_engine_option_callback(engine, callback_kind, std::string_view{}, 0);
        default:
            return std::nullopt;
        }
    };
}

}  // namespace

extern "C" {
void        zfish_engine_init_body(void* engine_ptr);

void zfish_engine_set_start_position(void* engine_ptr) {
    auto* engine = static_cast<Engine*>(engine_ptr);
    const auto* start_fen = reinterpret_cast<const unsigned char*>(StartFEN);
    const auto  error = zfish_engine_set_position_owner(
      engine, start_fen, std::char_traits<char>::length(StartFEN), nullptr, 0);
    if (error)
        std::abort();
}

void zfish_engine_add_option(void*                engine_ptr,
                             const unsigned char* name_ptr,
                             std::size_t          name_len,
                             std::uint8_t         option_kind,
                             const unsigned char* default_ptr,
                             std::size_t          default_len,
                             int                  default_value,
                             int                  min_value,
                             int                  max_value,
                             std::uint8_t         callback_kind) {
    auto* engine = static_cast<Engine*>(engine_ptr);
    auto   name   = std::string(reinterpret_cast<const char*>(name_ptr), name_len);
    auto   change = make_option_callback(engine, option_kind, callback_kind);

    switch (option_kind)
    {
    case kOptionTypeString: {
        auto default_text = std::string(reinterpret_cast<const char*>(default_ptr), default_len);
        engine->get_options().add(name, Option(default_text.c_str(), std::move(change)));
        return;
    }
    case kOptionTypeCheck:
        engine->get_options().add(name, Option(default_value != 0, std::move(change)));
        return;
    case kOptionTypeSpin:
        engine->get_options().add(
          name, Option(default_value, min_value, max_value, std::move(change)));
        return;
    case kOptionTypeButton:
        engine->get_options().add(name, Option(std::move(change)));
        return;
    default:
        std::abort();
    }
}

void zfish_engine_start_logger(const unsigned char* name_ptr, std::size_t name_len) {
    start_logger(std::string(reinterpret_cast<const char*>(name_ptr), name_len));
}


const char* zfish_engine_numa_config_info_text(const void* engine_ptr) {
    const char* rendered = zfish_engine_numa_config_information_owner(engine_ptr);
    if (!rendered)
        return nullptr;

    const std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return alloc_c_string(value);
}

const char* zfish_engine_thread_allocation_info_text(const void* engine_ptr) {
    const char* rendered = zfish_engine_thread_allocation_information_owner(engine_ptr);
    if (!rendered)
        return nullptr;

    const std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return alloc_c_string(value);
}

const char* zfish_engine_evalfile_text(const void* engine_ptr) {
    return alloc_c_string(std::string(static_cast<const Engine*>(engine_ptr)->get_options()["EvalFile"]));
}

const char* zfish_engine_numa_config_text(const void* engine_ptr) {
    return alloc_c_string(static_cast<const Engine*>(engine_ptr)->numaContext.get_numa_config().to_string());
}

void* zfish_engine_position_ptr(void* engine_ptr) {
    return &static_cast<Engine*>(engine_ptr)->pos;
}

const void* zfish_engine_options_ptr(const void* engine_ptr) {
    return &static_cast<const Engine*>(engine_ptr)->options;
}

void* zfish_engine_numa_context_ptr(void* engine_ptr) {
    return &static_cast<Engine*>(engine_ptr)->numaContext;
}

void* zfish_engine_states_slot_ptr(void* engine_ptr) {
    return &static_cast<Engine*>(engine_ptr)->states;
}

void zfish_engine_states_slot_reset(void* states_slot_ptr) {
    static_cast<StateListPtr*>(states_slot_ptr)->reset();
}

const void* zfish_engine_network_ptr(const void* engine_ptr) {
    return static_cast<const Engine*>(engine_ptr)->network.operator->();
}

void* zfish_engine_threads_ptr(void* engine_ptr) {
    return &static_cast<Engine*>(engine_ptr)->threads;
}

void* zfish_engine_tt_ptr(void* engine_ptr) {
    return &static_cast<Engine*>(engine_ptr)->tt;
}

void* zfish_engine_shared_hists_ptr(void* engine_ptr) {
    return &static_cast<Engine*>(engine_ptr)->sharedHists;
}

void* zfish_engine_network_replicated_ptr(void* engine_ptr) {
    return &static_cast<Engine*>(engine_ptr)->network;
}

const void* zfish_engine_update_context_ptr(const void* engine_ptr) {
    return &static_cast<const Engine*>(engine_ptr)->updateContext;
}

const void* zfish_numa_context_config(const void* numa_context_ptr) {
    return &static_cast<const NumaReplicationContext*>(numa_context_ptr)->get_numa_config();
}

void* zfish_search_shared_state_create(const void* options_ptr,
                                       void*       threads_ptr,
                                       void*       tt_ptr,
                                       void*       shared_hists_ptr,
                                       const void* network_ptr) {
    const auto& options = *static_cast<const OptionsMap*>(options_ptr);
    auto&       threads = *static_cast<ThreadPool*>(threads_ptr);
    auto&       tt      = *static_cast<TranspositionTable*>(tt_ptr);
    auto&       shared_hists =
      *static_cast<std::map<NumaIndex, SharedHistories>*>(shared_hists_ptr);
    const auto& network =
      *static_cast<const LazyNumaReplicatedSystemWide<Eval::NNUE::Network>*>(network_ptr);

    return new Search::SharedState(options, threads, tt, shared_hists, network);
}

void zfish_search_shared_state_destroy(void* shared_state_ptr) {
    delete static_cast<Search::SharedState*>(shared_state_ptr);
}

std::size_t zfish_engine_option_hash_value(const void* options_ptr) {
    return static_cast<std::size_t>((*static_cast<const OptionsMap*>(options_ptr))["Hash"]);
}

void zfish_engine_tt_resize(void* tt_ptr, std::size_t mb, void* threads_ptr) {
    static_cast<TranspositionTable*>(tt_ptr)->resize(mb, *static_cast<ThreadPool*>(threads_ptr));
}

void zfish_engine_tt_clear(void* tt_ptr, void* threads_ptr) {
    static_cast<TranspositionTable*>(tt_ptr)->clear(*static_cast<ThreadPool*>(threads_ptr));
}

char* zfish_engine_syzygy_path_text(const void* engine_ptr) {
    return alloc_c_string(std::string(static_cast<const Engine*>(engine_ptr)->get_options()["SyzygyPath"]));
}

int zfish_engine_tt_hashfull(const void* engine_ptr, int max_age) {
    return static_cast<const Engine*>(engine_ptr)->tt.hashfull(max_age);
}

std::uint8_t zfish_engine_chess960_enabled(const void* engine_ptr) {
    return static_cast<std::uint8_t>(static_cast<int>(static_cast<const Engine*>(engine_ptr)->get_options()["UCI_Chess960"]));
}

void zfish_engine_emit_verify_message(const void*          engine_ptr,
                                      const unsigned char* message_ptr,
                                      std::size_t          message_len) {
    const auto* engine = static_cast<const Engine*>(engine_ptr);
    if (!engine->onVerifyNetwork)
        return;

    engine->onVerifyNetwork(
      std::string_view(reinterpret_cast<const char*>(message_ptr), message_len));
}
}

Engine::Engine(std::optional<std::string> path) :
        binaryDirectory(path ? CommandLine::get_binary_directory(*path) : ""),
        numaContext(NumaConfig::from_system(DefaultNumaPolicy)),
        states(new std::deque<StateInfo>(1)),
        threads(),
        network(numaContext, get_default_network()) {
        zfish_engine_init_body(this);
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

struct ZfishUciDispatchResult {
    std::uint8_t should_quit;
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
std::uint8_t  zfish_position_is_repetition_method(const void* pos_ptr, int ply);
std::uint8_t  zfish_position_is_draw_method(const void* pos_ptr, int ply);
std::uint8_t  zfish_position_upcoming_repetition_method(const void* pos_ptr, int ply);
std::uint8_t  zfish_position_has_repeated_method(const void* pos_ptr);
std::uint64_t zfish_position_attackers_to_method(const void*  pos_ptr,
                                                 std::uint8_t  s,
                                                 std::uint64_t occupied);
std::uint8_t  zfish_position_attackers_to_exist_method(const void*   pos_ptr,
                                                       std::uint8_t  s,
                                                       std::uint64_t occupied,
                                                       std::uint8_t  c);
void          zfish_position_update_slider_blockers_method(const void* pos_ptr, std::uint8_t c);
void          zfish_position_set_check_info_method(const void* pos_ptr);
void          zfish_position_set_castling_right_method(void* pos_ptr, std::uint8_t c,
                                                       std::uint8_t rfrom);
const char*   zfish_position_flip_fen(const unsigned char* fen_ptr, std::size_t fen_len);
const char*   zfish_position_set_method(void* pos_ptr, const unsigned char* fen_ptr,
                                        std::size_t fen_len, std::uint8_t is_chess960, void* st_ptr,
                                        std::size_t pos_size, std::size_t st_size);
void          zfish_position_set_state_method(const void* pos_ptr);
std::uint8_t  zfish_position_legal_method(const void* pos_ptr, std::uint16_t move);
std::uint8_t  zfish_position_gives_check_method(const void* pos_ptr, std::uint16_t move);
std::uint8_t  zfish_position_pseudo_legal_method(const void* pos_ptr, std::uint16_t move);
std::uint8_t  zfish_position_see_ge_method(const void* pos_ptr, std::uint16_t move, int threshold);
void          zfish_position_do_null_move(void* pos_ptr, void* new_st_ptr);
void          zfish_position_undo_null_move(void* pos_ptr);
void          zfish_position_undo_move_method(void* pos_ptr, std::uint16_t move);
void          zfish_position_do_move(void* pos_ptr, std::uint16_t move, void* new_st_ptr,
                                     std::uint8_t gives_check, void* dp_ptr, void* dts_ptr);
void          zfish_position_init_runtime();
const char*   zfish_bitboard_pretty(Stockfish::Bitboard bitboard);
void          zfish_bitboards_init();
}

namespace {

std::string take_string_and_free(const char* rendered) {
    if (!rendered)
        return {};

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

std::string take_string_and_free_required(const char* rendered) {
    if (!rendered)
        std::abort();

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

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

void Engine::flip() { pos.flip(); }

extern "C" {

void zfish_bitboards_init() {
    Stockfish::Bitboards::init();
}

}

namespace Bitboards {

void init() {
    zfish_bitboards_init_magics_runtime(&BitboardMagicEntries, RookTable.data(), BishopTable.data());
    assign_magic_entries();

    zfish_bitboards_init_runtime(&PopCnt16, &SquareDistance, &LineBB, &BetweenBB, &RayPassBB);
}

std::string pretty(Bitboard b) { return take_string_and_free(zfish_bitboard_pretty(b)); }

}  // namespace Bitboards

Key Position::compute_material_key() const {
    return zfish_position_compute_material_key(pieceCount, PIECE_NB);
}

std::optional<PositionSetError> Position::set(const std::string& code, Color c, StateInfo* si) {
    const auto fenStr = take_string_and_free_required(zfish_position_build_endgame_fen(
      reinterpret_cast<const unsigned char*>(code.data()), code.size(), static_cast<std::uint8_t>(c)));
    return set(fenStr, false, si);
}

std::string Position::fen() const {
    const auto whiteOoRook = can_castle(WHITE_OO) ? castling_rook_square(WHITE_OO) : SQ_NONE;
    const auto whiteOooRook = can_castle(WHITE_OOO) ? castling_rook_square(WHITE_OOO) : SQ_NONE;
    const auto blackOoRook = can_castle(BLACK_OO) ? castling_rook_square(BLACK_OO) : SQ_NONE;
    const auto blackOooRook = can_castle(BLACK_OOO) ? castling_rook_square(BLACK_OOO) : SQ_NONE;

    return take_string_and_free_required(zfish_position_format_fen(
      reinterpret_cast<const unsigned char*>(board.data()), static_cast<std::uint8_t>(sideToMove),
      static_cast<std::uint8_t>(chess960), static_cast<std::uint8_t>(st->castlingRights),
      static_cast<std::uint8_t>(whiteOoRook), static_cast<std::uint8_t>(whiteOooRook),
      static_cast<std::uint8_t>(blackOoRook), static_cast<std::uint8_t>(blackOooRook),
      static_cast<std::uint8_t>(ep_square()), st->rule50, gamePly));
}

bool Position::is_repetition(int ply) const {
    return zfish_position_is_repetition_method(this, ply) != 0;
}

bool Position::is_draw(int ply) const { return zfish_position_is_draw_method(this, ply) != 0; }

bool Position::upcoming_repetition(int ply) const {
    return zfish_position_upcoming_repetition_method(this, ply) != 0;
}

bool Position::has_repeated() const { return zfish_position_has_repeated_method(this) != 0; }

Bitboard Position::attackers_to(Square s, Bitboard occupied) const {
    return zfish_position_attackers_to_method(this, static_cast<std::uint8_t>(s), occupied);
}

bool Position::attackers_to_exist(Square s, Bitboard occupied, Color c) const {
    return zfish_position_attackers_to_exist_method(this, static_cast<std::uint8_t>(s), occupied,
                                                    static_cast<std::uint8_t>(c))
        != 0;
}

void Position::update_slider_blockers(Color c) const {
    zfish_position_update_slider_blockers_method(this, static_cast<std::uint8_t>(c));
}

void Position::set_check_info() const { zfish_position_set_check_info_method(this); }

void Position::set_castling_right(Color c, Square rfrom) {
    zfish_position_set_castling_right_method(this, static_cast<std::uint8_t>(c),
                                             static_cast<std::uint8_t>(rfrom));
}

void Position::set_state() const { zfish_position_set_state_method(this); }

void Position::flip() {
    const std::string current = fen();
    const auto        flipped = take_string_and_free_required(zfish_position_flip_fen(
      reinterpret_cast<const unsigned char*>(current.data()), current.size()));
    set(flipped, is_chess960(), st);
}

std::optional<PositionSetError>
Position::set(const std::string& fenStr, bool isChess960, StateInfo* si) {
    const char* err = zfish_position_set_method(
      this, reinterpret_cast<const unsigned char*>(fenStr.data()), fenStr.size(),
      static_cast<std::uint8_t>(isChess960 ? 1 : 0), si, sizeof(Position), sizeof(StateInfo));
    if (err)
    {
        std::string message(err);
        std::free(const_cast<char*>(err));
        return PositionSetError(message);
    }
    return std::nullopt;
}

bool Position::legal(Move m) const { return zfish_position_legal_method(this, m.raw()) != 0; }

bool Position::gives_check(Move m) const {
    return zfish_position_gives_check_method(this, m.raw()) != 0;
}

bool Position::pseudo_legal(const Move m) const {
    return zfish_position_pseudo_legal_method(this, m.raw()) != 0;
}

bool Position::see_ge(Move m, int threshold) const {
    return zfish_position_see_ge_method(this, m.raw(), threshold) != 0;
}

void Position::do_null_move(StateInfo& newSt) { zfish_position_do_null_move(this, &newSt); }

void Position::undo_null_move() { zfish_position_undo_null_move(this); }

void Position::undo_move(Move m) { zfish_position_undo_move_method(this, m.raw()); }

void Position::do_move(Move                      m,
                       StateInfo&                newSt,
                       bool                      givesCheck,
                       DirtyPiece&               dp,
                       DirtyThreats&             dts,
                       const TranspositionTable* tt,
                       const SharedHistories*    worker) {
    (void) tt;      // prefetch hint only
    (void) worker;  // prefetch hint only
    zfish_position_do_move(this, m.raw(), &newSt, static_cast<std::uint8_t>(givesCheck ? 1 : 0), &dp,
                           &dts);
}

extern "C" const char* zfish_position_set_state(void*                pos_ptr,
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

extern "C" void zfish_position_do_move_state(void* pos_ptr, std::uint16_t move_raw, void* state_ptr) {
    static_cast<Position*>(pos_ptr)->do_move(Move(move_raw), *static_cast<StateInfo*>(state_ptr));
}

namespace {

}  // namespace

extern "C" {
void zfish_set_last_nodes_searched(std::uint64_t nodes);
}

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
    engine.set_on_update_full([this](const auto& i) {
        zfish_set_last_nodes_searched(i.nodes);
        on_update_full(i, engine.get_options()["UCI_ShowWDL"]);
    });
    engine.set_on_bestmove([](const auto& bm, const auto& p) { on_bestmove(bm, p); });
    engine.set_on_verify_network([](const auto& s) { print_info_string(s); });
}

extern "C" {

int zfish_uci_cli_argc(const void* uci_ptr) {
    return static_cast<const UCIEngine*>(uci_ptr)->cli.argc;
}

const char* zfish_uci_cli_arg_at(const void* uci_ptr, int index) {
    const auto* uci_engine = static_cast<const UCIEngine*>(uci_ptr);
    if (index < 0 || index >= uci_engine->cli.argc)
        return nullptr;

    return uci_engine->cli.argv[index];
}

void* zfish_uci_engine_ptr(void* uci_ptr) { return &static_cast<UCIEngine*>(uci_ptr)->engine; }

const char* zfish_engine_options_text_owner(const void* engine_ptr) {
    std::ostringstream options_stream;
    options_stream << static_cast<const Engine*>(engine_ptr)->get_options();
    return alloc_c_string(options_stream.str());
}

void zfish_uci_set_listener_mode(void* uci_ptr, std::uint8_t quiet_mode) {
    auto* uci_engine = static_cast<UCIEngine*>(uci_ptr);
    if (quiet_mode != 0)
    {
        uci_engine->engine.set_on_update_full([](const Engine::InfoFull& i) {
            zfish_set_last_nodes_searched(i.nodes);
        });
        uci_engine->engine.set_on_iter([](const auto&) {});
        uci_engine->engine.set_on_update_no_moves([](const auto&) {});
        uci_engine->engine.set_on_bestmove([](const auto&, const auto&) {});
        uci_engine->engine.set_on_verify_network([](const auto&) {});
    }
    else
    {
        uci_engine->init_search_update_listeners();
    }
}

void zfish_engine_apply_setoption_owner(void*                engine_ptr,
                                        const unsigned char* name_ptr,
                                        std::size_t          name_len,
                                        const unsigned char* value_ptr,
                                        std::size_t          value_len,
                                        std::uint8_t         has_value) {
    auto* engine = static_cast<Engine*>(engine_ptr);
    engine->wait_for_search_finished();

    std::ostringstream command;
    command << "name " << std::string(reinterpret_cast<const char*>(name_ptr), name_len);
    if (has_value != 0)
        command << " value " << std::string(reinterpret_cast<const char*>(value_ptr), value_len);

    std::istringstream is(command.str());
    engine->get_options().setoption(is);
}

std::uint64_t zfish_engine_perft_owner(void* engine_ptr, int depth) {
    auto* engine = static_cast<Engine*>(engine_ptr);
    zfish_engine_verify_network_method(engine);

    const char* rendered_fen = zfish_engine_fen(&engine->pos);
    if (!rendered_fen)
        std::abort();

    const std::string fen(rendered_fen);
    std::free(const_cast<char*>(rendered_fen));

    const auto nodes = Benchmark::perft(fen, depth, engine->get_options()["UCI_Chess960"]);
    sync_cout << "\nNodes searched: " << nodes << "\n" << sync_endl;
    return nodes;
}

void zfish_engine_go_parsed_owner(void* engine_ptr, ZfishParsedLimits parsed) {
    auto* engine = static_cast<Engine*>(engine_ptr);

    Search::LimitsType limits;
    limits.time[WHITE] = parsed.wtime;
    limits.time[BLACK] = parsed.btime;
    limits.inc[WHITE] = parsed.winc;
    limits.inc[BLACK] = parsed.binc;
    limits.movestogo = parsed.movestogo;
    limits.depth = parsed.depth;
    limits.mate = parsed.mate;
    limits.perft = parsed.perft;
    limits.infinite = parsed.infinite != 0;
    limits.movetime = parsed.movetime;
    limits.nodes = parsed.nodes;
    limits.ponderMode = parsed.ponder_mode != 0;

    if (parsed.searchmoves)
    {
        std::istringstream move_stream(parsed.searchmoves);
        std::string        move;
        while (std::getline(move_stream, move, '\n'))
            if (!move.empty())
                limits.searchmoves.push_back(move);
    }

    engine->go(limits);
}

void zfish_engine_flip_owner(void* engine_ptr) {
    static_cast<Engine*>(engine_ptr)->flip();
}

std::uint8_t zfish_limits_ponder_mode(const void* limits_ptr) {
    return static_cast<const Search::LimitsType*>(limits_ptr)->ponderMode ? 1 : 0;
}

std::size_t zfish_limits_perft_value(const void* limits_ptr) {
    return static_cast<std::size_t>(static_cast<const Search::LimitsType*>(limits_ptr)->perft);
}

std::size_t zfish_limits_searchmove_count(const void* limits_ptr) {
    return static_cast<const Search::LimitsType*>(limits_ptr)->searchmoves.size();
}

struct ZfishSearchMoveView {
    const unsigned char* ptr;
    std::size_t          len;
};

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

void zfish_threadpool_add_main_thread(void*       pool_ptr,
                                      const void* numa_config_ptr,
                                      const void* shared_state_ptr,
                                      const void* update_context_ptr,
                                      std::size_t thread_id,
                                      std::size_t idx_in_numa,
                                      std::size_t total_numa,
                                      std::size_t numa_id,
                                      std::uint8_t do_bind) {
    auto& pool = *static_cast<ThreadPool*>(pool_ptr);
    auto& shared_state =
      *const_cast<Search::SharedState*>(static_cast<const Search::SharedState*>(shared_state_ptr));
    const auto& update_context =
      *static_cast<const Search::SearchManager::UpdateContext*>(update_context_ptr);

    if (do_bind != 0)
    {
        const auto& numa_config = *static_cast<const NumaConfig*>(numa_config_ptr);
        pool.threads.emplace_back(std::make_unique<Thread>(
          shared_state, std::make_unique<Search::SearchManager>(update_context), thread_id,
          idx_in_numa, total_numa, OptionalThreadToNumaNodeBinder(numa_config, numa_id)));
        return;
    }

    pool.threads.emplace_back(std::make_unique<Thread>(
      shared_state, std::make_unique<Search::SearchManager>(update_context), thread_id, idx_in_numa,
      total_numa, OptionalThreadToNumaNodeBinder(numa_id)));
}

void zfish_threadpool_add_worker_thread(void*       pool_ptr,
                                        const void* numa_config_ptr,
                                        const void* shared_state_ptr,
                                        std::size_t thread_id,
                                        std::size_t idx_in_numa,
                                        std::size_t total_numa,
                                        std::size_t numa_id,
                                        std::uint8_t do_bind) {
    auto& pool = *static_cast<ThreadPool*>(pool_ptr);
    auto& shared_state =
      *const_cast<Search::SharedState*>(static_cast<const Search::SharedState*>(shared_state_ptr));

    if (do_bind != 0)
    {
        const auto& numa_config = *static_cast<const NumaConfig*>(numa_config_ptr);
        pool.threads.emplace_back(std::make_unique<Thread>(
          shared_state, std::make_unique<Search::NullSearchManager>(), thread_id, idx_in_numa,
          total_numa, OptionalThreadToNumaNodeBinder(numa_config, numa_id)));
        return;
    }

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

void zfish_numa_context_set_system(void* numa_context_ptr) {
    auto& numa_context = *static_cast<NumaReplicationContext*>(numa_context_ptr);
    numa_context.set_numa_config(NumaConfig::from_system(DefaultNumaPolicy));
}

void zfish_numa_context_set_hardware(void* numa_context_ptr) {
    auto& numa_context = *static_cast<NumaReplicationContext*>(numa_context_ptr);
    numa_context.set_numa_config(NumaConfig::from_system(DefaultNumaPolicy, false));
}

void zfish_numa_context_set_none(void* numa_context_ptr) {
    static_cast<NumaReplicationContext*>(numa_context_ptr)->set_numa_config(NumaConfig{});
}

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

void zfish_uci_destroy_engine(void* engine_ptr) {
    auto* uci_engine = static_cast<Stockfish::UCIEngine*>(engine_ptr);
    zfish_engine_release_pending_state_slot(&uci_engine->engine.states);
    delete uci_engine;
}
}
