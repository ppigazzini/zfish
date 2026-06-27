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
void*       zfish_engine_network_replicated_ptr(void* engine_ptr);
const void* zfish_engine_update_context_ptr(const void* engine_ptr);
void*       zfish_engine_onverifynetwork_ptr(void* engine_ptr);
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
struct ZfishEngineTablebaseProbe {
    std::uint8_t available;
    int          wdl;
    int          wdl_state;
    int          dtz;
    int          dtz_state;
};

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

void zfish_network_load(void*                network,
                        const unsigned char* root_directory_ptr,
                        std::size_t          root_directory_len,
                        const unsigned char* evalfile_path_ptr,
                        std::size_t          evalfile_path_len);
ZfishNetworkEvalOutput zfish_network_evaluate(const void* network,
                                              const void* pos,
                                              void*       accumulator_stack,
                                              void*       cache);

std::size_t zfish_network_content_hash(const void* network);

ZfishByteView zfish_network_embedded_bytes() {
    return {reinterpret_cast<const unsigned char*>(gEmbeddedNNUEData), std::size_t(gEmbeddedNNUESize)};
}

// M-FINAL cutover: these dual-write the C++ Network's EvalFile state (initialized flag,
// current name, description). In the DEFAULT build the native load owns that state (network.zig
// nn_* globals) and nothing reads the C++ Network's EvalFile — so these are no-ops. The LEGACY
// oracle keeps the real writes: the C++ eval / verify reads the C++ EvalFile.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#else
void zfish_network_mark_initialized(void*) {}
void zfish_network_set_loaded_state(void*, const unsigned char*, std::size_t,
                                    const unsigned char*, std::size_t) {}
#endif

// M-FINAL cutover: in the DEFAULT build the native NNUE parse (network.zig) is the SOLE parse —
// it writes the Zig-owned inference storage and advances the load offset from its own consumed
// count, and the eval gates + the offset==bytes.len check verify correctness end-to-end. So the
// default read_blob stubs are Network-free no-ops (the C++ Network is not parsed/used at runtime).
// The LEGACY oracle keeps the real parse: it populates the C++ Network the legacy C++ eval reads.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#else
// Default build: the C++ Network is not parsed (native storage is the source). No-op.
std::size_t zfish_network_feature_transformer_read_blob(void*, const unsigned char*, std::size_t) {
    return 0;
}
std::size_t zfish_network_layer_read_blob(void*, std::size_t, const unsigned char*, std::size_t) {
    return 0;
}
#endif

// M-FINAL cutover: dead in the default build — the native serialization round-trip
// self-check that read these was retired (redundant). The native save path serializes from
// native storage. Legacy oracle keeps them.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif

// M-FINAL cutover: dead in the default build — the load-time native-vs-C++ content-hash
// cross-check was retired with the C++ parse (the native parse is the sole source). Legacy keeps these.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif

// The NNUE feature-transformer forward pass (transform) is now Zig-owned
// (zfish_network_transform_bucket in zig_src/main.zig). The bridge only exposes
// the FeatureTransformer pointer so the Zig accumulator evaluate can read its
// weights -- the same pointer the C++ AccumulatorStack::evaluate passed.
// M-FINAL cutover: dead in the default build — the native parse cross-check byte-compare
// that read this was retired (redundant with the FT content-hash cross-check + the eval
// gates). Legacy oracle keeps it.
#ifdef ZFISH_LEGACY_CPP_TARGET
const void* zfish_network_feature_transformer_ptr(const void* network_ptr) {
        const auto& network = *static_cast<const Network*>(network_ptr);
        return &NetworkBridgeAccess::featureTransformer(network);
}
#endif

// Per-bucket affine-layer weight/bias pointers for the Zig propagate
// (zfish_network_propagate_bucket in network.zig). idx 0=fc_0, 1=fc_1, 2=fc_2.
// Biases are stored linearly (int32); weights are int8 in the SSSE3-scrambled
// layout, which the Zig side un-scrambles with get_weight_index_scrambled.
// Zig queries: native-owned layer storage if adopted, else nullptr. Defined in
// zig_src/main.zig. is_weights selects weights (1) vs biases (0).
extern "C" const void* zfish_native_layer_ptr(std::size_t bucket, int idx, int is_weights);

// M-FINAL cutover: dead in the default build — the eval reads layer weights from native
// storage (zfish_native_layer_ptr) and the parse cross-check byte-compare was retired.
// Legacy oracle keeps these C++ layer data accessors.
#ifdef ZFISH_LEGACY_CPP_TARGET
const std::int32_t* zfish_layer_biases(const void* network_ptr, std::size_t bucket, int idx) {
        if (auto* p = zfish_native_layer_ptr(bucket, idx, 0))
            return static_cast<const std::int32_t*>(p);
        const auto& l = NetworkBridgeAccess::layer(*static_cast<const Network*>(network_ptr), bucket);
        return idx == 0 ? l.fc_0.biases : idx == 1 ? l.fc_1.biases : l.fc_2.biases;
}

const std::int8_t* zfish_layer_weights(const void* network_ptr, std::size_t bucket, int idx) {
        if (auto* p = zfish_native_layer_ptr(bucket, idx, 1))
            return static_cast<const std::int8_t*>(p);
        const auto& l = NetworkBridgeAccess::layer(*static_cast<const Network*>(network_ptr), bucket);
        return idx == 0 ? l.fc_0.weights : idx == 1 ? l.fc_1.weights : l.fc_2.weights;
}
#endif

// Exact in-memory sizes of each affine layer's weight / bias arrays.
// M-FINAL cutover: dead in the default build — the native parse uses native size constants
// (network.zig layer_biases_bytes/layer_weights_bytes = {128,128,4}/{32768,2048,32}). Legacy
// oracle keeps these sizeof-the-C++-AffineTransform queries.
#ifdef ZFISH_LEGACY_CPP_TARGET
std::size_t zfish_layer_weights_bytes(const void* network_ptr, std::size_t bucket, int idx) {
        const auto& l = NetworkBridgeAccess::layer(*static_cast<const Network*>(network_ptr), bucket);
        return idx == 0 ? sizeof(l.fc_0.weights) : idx == 1 ? sizeof(l.fc_1.weights) : sizeof(l.fc_2.weights);
}

std::size_t zfish_layer_biases_bytes(const void* network_ptr, std::size_t bucket, int idx) {
        const auto& l = NetworkBridgeAccess::layer(*static_cast<const Network*>(network_ptr), bucket);
        return idx == 0 ? sizeof(l.fc_0.biases) : idx == 1 ? sizeof(l.fc_1.biases) : sizeof(l.fc_2.biases);
}
#endif

// zfish_network_propagate_bucket is now Zig-owned (network.zig). The bridge only
// exposes the per-layer weight/bias pointers above.

// M-FINAL cutover: dead in the default build — the native verify (network.zig) emits the
// architecture dims as native constants (they are sizeof/static-constexpr, data-independent).
// Legacy oracle keeps the C++ Network query.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif
}

void Network::load(const std::string& rootDirectory, std::string evalfilePath) {
    zfish_network_load(this,
                       reinterpret_cast<const unsigned char*>(rootDirectory.data()),
                       rootDirectory.size(),
                       reinterpret_cast<const unsigned char*>(evalfilePath.data()),
                       evalfilePath.size());
}

// M-FINAL cutover: dead in the default build (the native search evaluates via
// zfish_network_evaluate / zfish_eval_compute_value directly; this C++ Network::evaluate
// shim's only caller is the dead Eval::evaluate below). Legacy oracle keeps it.
#ifdef ZFISH_LEGACY_CPP_TARGET
NetworkOutput Network::evaluate(const Position&    pos,
                                AccumulatorStack&  accumulatorStack,
                                AccumulatorCaches& cache) const {
    const auto output = zfish_network_evaluate(this, &pos, &accumulatorStack, &cache);
    return {static_cast<Value>(output.psqt), static_cast<Value>(output.positional)};
}
#endif

std::size_t Network::get_content_hash() const {
    return zfish_network_content_hash(this);
}

}  // namespace Eval::NNUE
}


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

extern "C" void zfish_search_fill_reductions(int* reductions, std::size_t count);
extern "C" void zfish_search_clear_worker_histories(void* worker_ptr);
extern "C" std::uint8_t zfish_search_iterative_deepening(void* worker);
extern "C" std::uint8_t zfish_search_extract_ponder_from_tt(void* pv, void* table,
                                                           std::size_t cc, std::uint8_t gen,
                                                           void* pos);
extern "C" void zfish_search_clear_shared_history(void* shared, std::size_t thread_idx,
                                                  std::size_t numa_total);
extern "C" void zfish_search_clear_refresh_cache(void* cache, const std::int16_t* biases);
extern "C" const void* zfish_native_ft_ptr();  // native FT storage (biases start)

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
// M-FINAL: zfish_now ported to native CLOCK_MONOTONIC (default build); legacy-oracle-only.
#ifdef ZFISH_LEGACY_CPP_TARGET
extern "C" std::int64_t zfish_now() { return Stockfish::now(); }
#endif

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

// zfish_search_id_state is native (main.zig) in the default build. It reads the
// native option model (MultiPV / Skill Level), which is only populated in the
// default build, so the legacy oracle keeps this C++ body (gated) that reads the
// C++ OptionsMap instead. The native @export is default-only via target_flags.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif

// UCI pv() sink (output only -- not parity-observable).
// SearchManager::pv dispatches to the native pv driver in the default build and
// the C++ pv() in the legacy oracle, so this stays a C++ method call (a native
// direct call to zfish_search_pv would force the native driver in legacy too,
// defeating the oracle).
extern "C" void zfish_search_pv(void* manager, void* worker, void* threads, void* tt, int depth);
extern "C" void zfish_search_id_pv(void* worker, int depth) {
    auto* w = static_cast<Stockfish::Search::Worker*>(worker);
#ifndef ZFISH_LEGACY_CPP_TARGET
    // M-FINAL cutover: call the native pv driver directly (the default's SearchManager::pv only
    // forwarded here anyway), so the C++ SearchManager::pv goes legacy-only.
    zfish_search_pv(w->main_manager(), w, &w->threads, &w->tt, depth);
#else
    w->main_manager()->pv(*w, w->threads, w->tt, depth);
#endif
}

// Cross-thread bestMoveChanges collection: sum and reset, returned as a double
// (keeps the multi-thread result correct from one extern).
// zfish_search_id_collect_bmc is native (main.zig): sums and resets each thread's
// worker bestMoveChanges by offset. Bridge-only symbol.

// zfish_search_cb_worker_state is native (main.zig): it snapshots the Worker /
// SearchManager / ThreadPool / LimitsType state the ported search reads, resolving
// every field by offset. The one piece that needs C++ is the network instance --
// &w->network[token] indexes a LazyNumaReplicated (vtable + private instances
// vector + mutex), so the native snapshot calls this thin resolver. The returned
// pointer is a stable handle held for the search tree; in the default build it is
// never dereferenced (NNUE weights are served from native storage), but the legacy
// oracle's C++ inference may deref it, so it must be the exact replicated instance.
extern "C" const void* zfish_worker_resolve_network(void* worker) {
#ifndef ZFISH_LEGACY_CPP_TARGET
    // M-FINAL cutover (decouple step 2): the handle is never dereferenced in the default build
    // (weights served from native storage), so return a stable non-null handle WITHOUT
    // evaluating network[token] — which would trigger the lazy 106 MB numa replication of the
    // C++ Network. native_ft_ptr is a stable, always-resident handle.
    (void) worker;
    return zfish_native_ft_ptr();
#else
    auto* w = static_cast<Stockfish::Search::Worker*>(worker);
    return &w->network[w->numaAccessToken];
#endif
}

// zfish_search_cb_tt_context is native (main.zig): it resolves the worker TT
// reference and reads table/clusterCount/generation8 by offset. Bridge-only.

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

// zfish_search_cb_root_on_iter is native (main.zig): on the main thread it prints
// "info depth D currmove X currmovenumber N" via the native move formatter and
// formatInfoIter. Bridge-only symbol, no gating.

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

ZfishTimemanOutput zfish_timeman_init(ZfishTimemanInput input);
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

void zfish_thread_run_callback(void* thread_ptr, ZfishOpaqueCallback callback, void* context);
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

// Worker::clear runs the four Zig-owned resets: per-worker histories, the shared
// correction/pawn history, the reductions table, and the NNUE refresh cache.
// NOTE (M-FINAL): default-LIVE — the worker ctor's clear() reads the FT biases from the
// C++ Network here, so the C++ Network is NOT vestigial at runtime (the refresh cache +
// lazy replication keep it live). Porting it native is part of the network+numa giant.
void Search::Worker::clear() {
    zfish_search_clear_worker_histories(this);
    zfish_search_clear_shared_history(&sharedHistory, numaThreadIdx, numaTotal);
    zfish_search_fill_reductions(reductions.data(), reductions.size());
#ifndef ZFISH_LEGACY_CPP_TARGET
    // M-FINAL cutover: read the FT biases from the native FT storage (bit-identical to the
    // C++ Network FT, cross-checked at load) — decouples the worker refresh cache from the
    // C++ Network. Step 1 of decoupling the runtime from the C++ Network.
    zfish_search_clear_refresh_cache(
      &refreshTable, reinterpret_cast<const std::int16_t*>(zfish_native_ft_ptr()));
#else
    zfish_search_clear_refresh_cache(&refreshTable,
                                     network[numaAccessToken].featureTransformer.biases.data());
#endif
}

void Search::Worker::ensure_network_replicated() {
#ifdef ZFISH_LEGACY_CPP_TARGET
    (void) (network[numaAccessToken]);  // force lazy numa initialization off the search path
#endif
    // M-FINAL cutover (decouple step 3): default build serves weights from native storage
    // (always resident), so no C++ Network numa replica is needed — no-op.
}

// M-FINAL cutover: legacy-only. Its only caller was the C++ Worker::start_searching driver (now
// legacy-only); the native pv driver runs zfish_search_extract_ponder_from_tt (main.zig) directly.
// Dead in the default build — removes RootMove/TT/Position member access (pv/table/clusterCount).
#ifdef ZFISH_LEGACY_CPP_TARGET
bool Search::RootMove::extract_ponder_from_tt(const TranspositionTable& tt, Position& pos) {
    return bool(zfish_search_extract_ponder_from_tt(&pv, tt.table, tt.clusterCount,
                                                    tt.generation8, &pos));
}
#endif

// Worker constructor relocated verbatim from search.cpp: unpack the SharedState
// into members and run the initial clear().
// M-FINAL cutover (decouple step 4): dead in the default build — the native
// zfish_worker_construct_full (worker_native_construct.zig) writes the field set + runs
// the clear pieces, sourcing the FT biases from native_ft_ptr, so no C++ placement-new of
// Worker via this ctor happens. This ctor's refreshTable(network[token]) was the LAST
// default-build C++ Network[token] access; guarding it legacy-only makes the C++ Network
// fully runtime-vestigial in the default build.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif

// M-FINAL cutover (thread cluster): ThreadPool::nodes_searched()/tb_hits() accumulate. The
// default build uses the native offset-iteration over the threads vector (zig_src/main.zig);
// the legacy oracle keeps the C++ methods. All call sites go through these helpers.
#ifndef ZFISH_LEGACY_CPP_TARGET
extern "C" std::uint64_t zfish_threadpool_nodes_searched(const void* pool);
extern "C" std::uint64_t zfish_threadpool_tb_hits(const void* pool);
static inline std::uint64_t zfish_pool_nodes(const ThreadPool& t) { return zfish_threadpool_nodes_searched(&t); }
static inline std::uint64_t zfish_pool_tbhits(const ThreadPool& t) { return zfish_threadpool_tb_hits(&t); }
#else
static inline std::uint64_t zfish_pool_nodes(const ThreadPool& t) { return t.nodes_searched(); }
static inline std::uint64_t zfish_pool_tbhits(const ThreadPool& t) { return t.tb_hits(); }
#endif

// SearchManager::pv (UCI info output). The default target delegates to the
// Zig-owned driver (zfish_search_pv, below); the C++ body is retained for the
// legacy oracle. syzygy_extend_pv is dead in this no-tablebase build (rootInTB
// is always false, so v never lands in the decisive-non-mate TB range).
extern "C" void zfish_search_pv(void* manager, void* worker, void* threads, void* tt, int depth);
// M-FINAL cutover: legacy-only. The default build's pv callers (zfish_search_id_pv / zfish_ss_emit_pv)
// now call the native pv driver (zfish_search_pv) directly, so this C++ SearchManager::pv is dead in
// the default build (and the vtable it once shared concerns is already unreferenced — 91a7e6af).
#ifdef ZFISH_LEGACY_CPP_TARGET
void Search::SearchManager::pv(Search::Worker&           worker,
                               const ThreadPool&         threads,
                               const TranspositionTable& tt,
                               Depth                     depth) {
    const auto nodes     = zfish_pool_nodes(threads);
    auto&      rootMoves = worker.rootMoves;
    auto&      pos       = worker.rootPos;
    std::size_t multiPV  = std::min(std::size_t(worker.options["MultiPV"]), rootMoves.size());
    std::uint64_t tbHits = zfish_pool_tbhits(threads) + (worker.tbConfig.rootInTB ? rootMoves.size() : 0);

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
#endif  // ZFISH_LEGACY_CPP_TARGET

// Context + emit seams for the Zig-owned pv() driver (default target only). The
// context fetch hands Zig every value the multiPV loop needs; the emit callback
// rebuilds InfoFull for one line and routes it through the unchanged
// updates.onUpdateFull listener (this build has no tablebases, so rootInTB is
// always false and the TB/syzygy branches of the C++ pv never apply).
namespace {
struct ZfishPvContext {
    void*         manager;
    void*         worker;
    const void*   root_moves;
    std::size_t   root_moves_count;
    std::size_t   multipv;
    std::uint8_t  show_wdl;
    std::uint8_t  chess960;
    std::uint64_t nodes;
    std::uint64_t tb_hits;
    int           hashfull;
    std::uint64_t elapsed_ms;
};
}  // namespace

// zfish_search_cb_pv_context is native (main.zig): it fills ZfishPvContext from
// the worker rootMoves vector, the native option model (MultiPV/UCI_ShowWDL),
// the pool node/tb-hit aggregates, native TT hashfull, and elapsed = max(1, now -
// tm.startTime). Bridge-only symbol, no gating.

// zfish_search_emit_info_full is native (main.zig): it records the node count
// (always, as the C++ onUpdateFull lambda did in both modes), and in interactive
// mode classifies the score, formats cp/mate/WDL, renders the PV, assembles the
// "info .." line, and prints it through zfish_uci_print_line. Bridge-only symbol,
// no gating.

#ifdef ZFISH_LEGACY_CPP_TARGET
bool Search::Worker::iterative_deepening() { return bool(zfish_search_iterative_deepening(this)); }
#endif

// SearchManager::check_time relocated verbatim from search.cpp. The Zig search
// runs the per-node time check itself, so this is unused on the search path, but
// it is SearchManager's only virtual override and therefore anchors the class
// vtable in this translation unit.
// M-FINAL cutover TEST: try legacy-only — the Zig search runs the per-node time check itself, and
// the SearchManager construction-crack (raw buffer, no C++ ctor/vtable setup) means the default
// build may not reference the vtable that this virtual override anchors. If the link succeeds, the
// C++ SearchManager vtable is truly unreferenced in default (a step toward forward-declaring it).
#ifdef ZFISH_LEGACY_CPP_TARGET
void Search::SearchManager::check_time(Search::Worker& worker) {
    if (--callsCnt > 0)
        return;

    callsCnt = worker.limits.nodes ? std::min(512, int(worker.limits.nodes / 1024)) : 512;

    static TimePoint lastInfoTime = now();

    TimePoint elapsed = tm.elapsed([&worker]() { return zfish_pool_nodes(worker.threads); });
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
        || (worker.limits.nodes && zfish_pool_nodes(worker.threads) >= worker.limits.nodes))
        worker.threads.stop = true;
}
#endif

// Worker::start_searching. The default target delegates the entire control flow
// to the Zig-owned driver (zfish_worker_start_searching, below): Zig owns every
// branch -- the non-main early return, the empty-rootmoves emit, the ponder/
// infinite busy wait, the npmsec advance, the best-thread selection, the
// ponder-extraction decision, and the pv-emit decision -- calling back into the
// leaf operations the C++ helpers expose. The C++ body below is retained for the
// legacy oracle, so the output-parity gate cross-checks the Zig port end to end.
extern "C" void zfish_worker_start_searching(void* worker);
// M-FINAL cutover: legacy-only. The native thread runtime runs the Zig search body
// (zfish_worker_start_searching) directly (native_thread.zig / thread.zig), never this C++ method —
// dead in the default build. Removes the C++ Worker/SearchManager member access in its driver body.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
        main_manager()->tm.advance_nodes_time(zfish_pool_nodes(threads)
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
#endif  // ZFISH_LEGACY_CPP_TARGET

// Leaf seams for the Zig-owned start_searching driver (default target only). Zig
// owns the sequencing and every branch; these helpers perform the individual
// C++ operations the driver decides to run, keeping the time-management,
// thread-pool, skill, and UCI-output subsystems on their existing C++ surfaces
// until they are themselves ported.
namespace {
struct ZfishSsCtx {
    std::uint8_t is_mainthread;
    std::uint8_t root_moves_empty;
    std::uint8_t npmsec;
    std::int32_t limits_depth;
    std::uint8_t skill_enabled;
};
}  // namespace

// zfish_ss_prologue is native (main.zig): it resets the worker's AccumulatorStack
// (native stackReset) and clears lastIterationPV (length = 0) by offset. Touches
// no options, so it is a plain export with no legacy gating.

// zfish_ss_context is native (main.zig): it snapshots is_mainthread / rootMoves
// empty / limits npmsec+depth by offset and skill_enabled from the native option
// model (Skill::enabled == level < 20). Bridge-only symbol, no gating.

// zfish_ss_tm_init is native (main.zig) in the default build: it builds the
// TimeManagement::init input from the worker's limits/rootPos + manager tm, runs
// the native timeman math, writes the outputs back, and bumps the TT generation.
// It reads the nodestime/Move Overhead/Ponder options, which are empty in the
// native model under the legacy oracle, so the legacy build keeps this C++ body
// (reading the C++ OptionsMap). See [[native-optionsmodel-default-only]].
#ifdef ZFISH_LEGACY_CPP_TARGET
extern "C" void zfish_ss_tm_init(void* worker) {
    auto* w = static_cast<Search::Worker*>(worker);
    w->main_manager()->tm.init(w->limits, w->rootPos.side_to_move(), w->rootPos.game_ply(),
                               w->options, w->main_manager()->originalTimeAdjust);
    w->tt.new_search();
}
#endif

// zfish_ss_emit_no_moves is native (main.zig): prints "info depth 0 score <fmt>"
// (mate 0 in check, else cp 0) and "bestmove (none)" in interactive mode.
// Bridge-only symbol, no gating.

extern "C" void zfish_ss_threads_start(void* worker) {
    static_cast<Search::Worker*>(worker)->threads.start_searching();
}

// zfish_ss_should_busywait and zfish_ss_set_stop are native (main.zig): they
// resolve worker->threads.stop, the worker manager's ponder flag, and
// limits.infinite by offset. Bridge-only symbols, so no legacy gating is needed.

extern "C" void zfish_ss_wait_finished(void* worker) {
    static_cast<Search::Worker*>(worker)->threads.wait_for_search_finished();
}

extern "C" void zfish_ss_npmsec_advance(void* worker) {
    auto* w = static_cast<Search::Worker*>(worker);
    w->main_manager()->tm.advance_nodes_time(zfish_pool_nodes(w->threads)
                                             - w->limits.inc[w->rootPos.side_to_move()]);
}

// zfish_ss_get_best_thread is native (main.zig): it calls the native voting
// (thread_port.bestThreadIndex, which ThreadPool::get_best_thread already bounced
// to in both builds) and resolves threads[idx]->worker by offset. Bridge-only
// symbol, no gating.

// zfish_ss_set_prev_scores is native (main.zig): it reads best->rootMoves[0]
// score/averageScore and stores them in worker's manager by offset. Bridge-only
// symbol, so no legacy gating is needed.

// zfish_ss_pv_one_and_ponder is native (main.zig): it tests best->rootMoves[0]
// pv.length == 1 by offset and, if so, runs the native extract_ponder_from_tt
// over best's pv with worker's tt/rootPos. Bridge-only symbol, no gating.

// Like zfish_search_id_pv, stays a C++ method call so the legacy oracle uses its
// C++ pv() while the default build routes to the native driver.
extern "C" void zfish_ss_emit_pv(void* worker, void* best) {
    auto* w = static_cast<Search::Worker*>(worker);
    auto* b = static_cast<Search::Worker*>(best);
#ifndef ZFISH_LEGACY_CPP_TARGET
    zfish_search_pv(w->main_manager(), b, &w->threads, &w->tt, b->rootDepth);
#else
    w->main_manager()->pv(*b, w->threads, w->tt, b->rootDepth);
#endif
}

// zfish_ss_emit_bestmove is native (main.zig): it renders pv[0]/pv[1] with the
// native move formatter and prints "bestmove .." through zfish_uci_print_line,
// no-op in quiet mode. Bridge-only symbol, no gating.

static_assert(sizeof(Move) == sizeof(std::uint16_t));


// zfish_position_has_repeated / is_draw_ply_one / is_repetition_ply_one retired:
// they forwarded to pos.has_repeated()/is_draw(1)/is_repetition(1), which already
// bounce to the native position_port methods in both builds, so the native
// rank_root_moves path now calls position_port directly (one fewer C++ hop).

// M-FINAL cutover (position-set port): native in the default build (zig_src/main.zig);
// legacy oracle keeps the C++ Position::legal.
#ifdef ZFISH_LEGACY_CPP_TARGET
extern "C" std::uint8_t zfish_position_move_is_legal(const void* pos_ptr,
                                                      std::uint16_t raw_move) {
    const auto& pos = *static_cast<const Position*>(pos_ptr);
    return std::uint8_t(pos.legal(Move(raw_move)) ? 1 : 0);
}
#endif

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

// M-FINAL cutover: dead in the default build — the native movepick/search generate moves
// via the zfish_movegen_* exports directly; only MoveList<LEGAL> (perft) instantiates a C++
// generate<> here. The CAPTURES/QUIETS/EVASIONS/NON_EVASIONS specializations have no default
// caller. Legacy oracle keeps them. generate<LEGAL> stays (perft uses it).
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif  // ZFISH_LEGACY_CPP_TARGET (dead C++ movegen specializations)

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

// zfish_threadpool_num_threads is native (main.zig): threads.size() via the
// threads-vector begin/end offsets.

// M-FINAL cutover (thread-cluster leaf): native in the default build (zig_src/main.zig
// zfishThreadpoolZeroTtSlice). Legacy oracle keeps the C++ ThreadPool::run_on_thread path.
#ifdef ZFISH_LEGACY_CPP_TARGET
extern "C" void zfish_threadpool_zero_tt_slice(void*        threads_ptr,
                                                 std::size_t thread_id,
                                                 void*       table_ptr,
                                                 std::size_t start_cluster,
                                                 std::size_t cluster_len) {
    if (cluster_len == 0 || !table_ptr)
        return;

    auto* table = static_cast<Cluster*>(table_ptr);
    auto* threads = static_cast<ThreadPool*>(threads_ptr);
    threads->run_on_thread(thread_id, [table, start_cluster, cluster_len]() {
        std::memset(&table[start_cluster], 0, cluster_len * sizeof(Cluster));
    });
}
#endif

#ifndef ZFISH_LEGACY_CPP_TARGET
extern "C" void zfish_native_threadpool_wait_thread(void* pool, std::size_t thread_id);
#endif
extern "C" void zfish_threadpool_wait_thread(void* threads_ptr, std::size_t thread_id) {
#ifdef ZFISH_LEGACY_CPP_TARGET
    static_cast<ThreadPool*>(threads_ptr)->wait_on_thread(thread_id);
#else
    // Stage-4: the pool holds native Threads; route to the native single-thread
    // wait (the C++ wait_on_thread would lock the native thread as a C++ Thread).
    zfish_native_threadpool_wait_thread(threads_ptr, thread_id);
#endif
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

// M-FINAL cutover: native model int read (default-build option authority), so TimeManagement::init
// reads nodestime / Move Overhead / Ponder from the Zig model instead of the C++ OptionsMap operator[].
extern "C" int zfish_optmodel_int_by_name(const unsigned char* name_ptr, std::size_t name_len);
static inline int zfish_opt_int_native(const char* n) {
    return zfish_optmodel_int_by_name(reinterpret_cast<const unsigned char*>(n),
                                      std::char_traits<char>::length(n));
}
void TimeManagement::init(Search::LimitsType& limits,
                          Color               us,
                          int                 ply,
                          const OptionsMap&   options,
                          double&             originalTimeAdjust) {
    (void) options;  // option values now sourced from the Zig model (default build)
    const ZfishTimemanInput input = {
      .time_us              = limits.time[us],
      .inc_us               = limits.inc[us],
      .start_time           = limits.startTime,
      .npmsec               = zfish_opt_int_native("nodestime"),
      .move_overhead        = zfish_opt_int_native("Move Overhead"),
      .available_nodes      = availableNodes,
      .current_optimum_time = optimumTime,
      .current_maximum_time = maximumTime,
      .movestogo            = limits.movestogo,
      .ply                  = ply,
      .original_time_adjust = originalTimeAdjust,
      .ponder               = static_cast<std::uint8_t>(zfish_opt_int_native("Ponder") ? 1 : 0),
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

// M-FINAL cutover: dead in the default build — the native search computes eval via
// zfish_eval_compute_value (zig_src) directly; this C++ Eval::evaluate has no default caller.
// Legacy oracle keeps it (its evaluate.cpp search calls it).
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif

// Stage-7 7.1: the default-only inert Tablebases:: stub block was deleted. The
// Zig runtime ships no Syzygy tablebases, so the default build now routes the
// three tablebase entry points (max_cardinality / probe_fen / init) through
// native-inert Zig exports (zig_src/main.zig, !legacy_target); no default
// reference to Tablebases:: remains. The legacy oracle keeps the real
// implementations from src/syzygy/tbprobe.cpp.

// Constructor launches the thread and waits until it goes to sleep in idle_loop().
// Read-only verifiers exported from zig_src/ (accumulator_layout.zig,
// worker_construct.zig).
extern "C" void zfish_verify_accumulator_caches(const void*);
extern "C" void zfish_verify_worker_construction(
  const void* worker, size_t thread_idx, const void* options_ref, const void* threads_ref,
  const void* tt_ref, const void* network_ref);
extern "C" void zfish_worker_construct_full(
  void* buf, size_t shared_history, size_t options, size_t threads, size_t tt, size_t network,
  size_t manager, size_t thread_idx, size_t numa_thread_idx, size_t numa_total,
  size_t numa_access_token);

// Stage-7 7.2d: the entire C++ Thread vehicle (ctor/dtor/idle_loop + sync +
// worker_* methods) is legacy-oracle-only. The default build runs the native
// futex thread runtime (native_thread.zig / native_threadpool.zig); thread.zig
// comptime-prunes the legacy branch. Because the bridge TU is not built with
// --gc-sections, these retained-but-unreferenced methods must be #ifdef'd out as
// one atomic cluster (they reference each other + ThreadPool::clear).
#ifdef ZFISH_LEGACY_CPP_TARGET
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
        // the Worker allocation.
        this->numaAccessToken = binder();
#ifndef ZFISH_LEGACY_CPP_TARGET
        // Construct the Worker natively: aligned_large_pages_alloc (Zig, zeroed)
        // for the storage, then the native constructor (zfish_worker_construct_full)
        // for the field init and Worker::clear -- no C++ placement-new. Proven
        // byte-identical to the C++ ctor by the full-construction self-check. The
        // LargePagePtr deleter still runs ~Worker on the (valid) bytes.
        void* raw = aligned_large_pages_alloc(sizeof(Search::Worker));
        zfish_worker_construct_full(
          raw,
          reinterpret_cast<size_t>(
            &sharedState.sharedHistories.at(this->numaAccessToken.get_numa_index())),
          reinterpret_cast<size_t>(&sharedState.options),
          reinterpret_cast<size_t>(&sharedState.threads),
          reinterpret_cast<size_t>(&sharedState.tt),
          reinterpret_cast<size_t>(&sharedState.network),
          reinterpret_cast<size_t>(sm.release()),
          n, idxInNuma, totalNuma, this->numaAccessToken.get_numa_index());
        this->worker = LargePagePtr<Search::Worker>(reinterpret_cast<Search::Worker*>(raw));
#else
        this->worker = make_unique_large_page<Search::Worker>(
          sharedState, std::move(sm), n, idxInNuma, totalNuma, this->numaAccessToken);
#endif
    });

    wait_for_search_finished();

#ifndef ZFISH_LEGACY_CPP_TARGET
    // Prove the Zig AccumulatorCaches construction model (bias prefix + zero
    // tail, repeated per entry) matches the freshly constructed C++ object.
    // Read-only cross-check; panics on any mismatch.
    zfish_verify_accumulator_caches(&this->worker->refreshTable);
    // Prove the Zig model of the constructed Worker is exact: the reference
    // members are bound to the SharedState referents, the manager is minted,
    // rootMoves is an empty vector and the AccumulatorStack reports size 1.
    zfish_verify_worker_construction(this->worker.get(), n, &sharedState.options,
                                     &sharedState.threads, &sharedState.tt, &sharedState.network);
#endif
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

#endif  // ZFISH_LEGACY_CPP_TARGET (pause: wait_for_search_finished is default-live)
// Blocks on the condition variable until the thread has finished searching.
// Default-live: referenced by ~ThreadPool() (thread.h inline) even though the
// Stage-4 teardown empties the threads vector so it never runs in the default exe.
void Thread::wait_for_search_finished() {

    std::unique_lock<std::mutex> lk(mutex);
    cv.wait(lk, [&] { return !searching; });
}
#ifdef ZFISH_LEGACY_CPP_TARGET  // resume the Thread vehicle gate

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

#endif  // ZFISH_LEGACY_CPP_TARGET (pause: ensure_network_replicated is default-live)
// Default-live: native thread.zig ensureNetworkReplicated → zfish_thread_ensure_
// network_replicated → here, once per thread in the default build.
void Thread::ensure_network_replicated() { worker->ensure_network_replicated(); }
#ifdef ZFISH_LEGACY_CPP_TARGET  // resume the Thread vehicle gate

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

#endif  // ZFISH_LEGACY_CPP_TARGET (C++ Thread vehicle)

// M-FINAL cutover (thread cluster): dead in the default build — every caller of
// ThreadPool::main_manager() is legacy-only (the legacy Worker::start_searching body, the
// legacy ThreadPool::clear, the legacy main_manager bridge fns); the default build navigates
// to the manager via the native zfish_threadpool_main_manager_ptr (zig_src/main.zig).
#ifdef ZFISH_LEGACY_CPP_TARGET
Search::SearchManager* ThreadPool::main_manager() { return main_thread()->worker->main_manager(); }
#endif

// M-FINAL cutover (thread cluster): native in the default build (zfish_pool_nodes/tbhits ->
// zig_src/main.zig offset-iteration). Legacy oracle keeps these C++ accumulate methods.
#ifdef ZFISH_LEGACY_CPP_TARGET
uint64_t ThreadPool::nodes_searched() const { return accumulate(&Search::Worker::nodes); }
uint64_t ThreadPool::tb_hits() const { return accumulate(&Search::Worker::tbHits); }
#endif

// Stage-7 7.2a: ThreadPool::set (+ its next_power_of_two helper) retired. The
// Stage-4 native thread runtime replaced it with native_threadpool.zig
// (zfish_native_threadpool_set, "mirrors ThreadPool::set's thread-creation loop");
// the only caller of the C++ method was src/engine.cpp:241, compiled in neither
// build (default builds only uci_bridge.cpp; legacy omits engine.cpp), so it was
// dead in both builds -- along with the two stale options["Threads"]/["NumaPolicy"]
// reads it carried.

// Stage-7 7.2d: legacy-only. The default build clears the pool via the native
// zfish_threadpool_clear export and waits/dispatches via the native runtime;
// these C++ methods call the (now legacy-gated) Thread vehicle.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif  // ZFISH_LEGACY_CPP_TARGET (dead ThreadPool methods)

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

#ifdef ZFISH_LEGACY_CPP_TARGET
std::size_t zfish_threadpool_thread_count(const void* pool_ptr) {
    return static_cast<const ThreadPool*>(pool_ptr)->size();
}
#endif

// thread_at(i) == threads[i].get(): native in the default build via the Zig
// export zfish_threadpool_thread_at (main.zig), which loads the i-th unique_ptr
// slot from the threads vector by offset. The legacy oracle uses src/thread.cpp.

#ifdef ZFISH_LEGACY_CPP_TARGET
void zfish_threadpool_set_stop_flag(void* pool_ptr, std::uint8_t stop) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->stop = stop != 0;
}
#endif

// Navigation helper: the main thread's SearchManager pointer. The native field
// shims (main.zig, default build only) write the manager's data members through
// this pointer using the search_manager_off offset map. Defined for both builds
// (legacy keeps the C++ field shims below). The native shims gate themselves to
// the default build to avoid clashing with the legacy definitions.
// M-FINAL: ported to native offset navigation (zig_src/main.zig) in the default build;
// this C++ wrapper is now legacy-oracle-only.
#ifdef ZFISH_LEGACY_CPP_TARGET
void* zfish_threadpool_main_manager_ptr(void* pool_ptr) {
    return static_cast<ThreadPool*>(pool_ptr)->main_manager();
}
#endif

#ifdef ZFISH_LEGACY_CPP_TARGET
void zfish_threadpool_main_manager_set_stop_on_ponderhit(void*       pool_ptr,
                                                         std::uint8_t stop_on_ponderhit) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->stopOnPonderhit = stop_on_ponderhit != 0;
}

void zfish_threadpool_main_manager_set_ponder(void* pool_ptr, std::uint8_t ponder_mode) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->ponder = ponder_mode != 0;
}
#endif

#ifdef ZFISH_LEGACY_CPP_TARGET
void zfish_threadpool_set_increase_depth(void* pool_ptr, std::uint8_t increase_depth) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->increaseDepth = increase_depth != 0;
}
#endif

// Stage-7 7.2c: the legacy thread-sync wrappers are legacy-oracle-only. thread.zig
// gates these at comptime now (target_flags.legacy_target), so the default build
// prunes the legacy branch and never references them -- only the legacy C++ Thread
// vehicle uses them.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif  // ZFISH_LEGACY_CPP_TARGET

// Default-live: native thread.zig ensureNetworkReplicated calls this per thread.
void zfish_thread_ensure_network_replicated(void* thread_ptr) {
    static_cast<Thread*>(thread_ptr)->ensure_network_replicated();
}

// Stage-7 7.2d: legacy-only thread-level worker-op wrappers. The default build
// uses the native zfish_worker_* / zfish_thread_worker_* exports (main.zig) for
// these; these forward to the legacy-gated C++ Thread::worker_* methods.
#ifdef ZFISH_LEGACY_CPP_TARGET
void zfish_thread_worker_set_limits(void* thread_ptr, const void* limits_ptr) {
    auto* thread = static_cast<Thread*>(thread_ptr);
    thread->worker_set_limits(*static_cast<const Search::LimitsType*>(limits_ptr));
}

// reset_root_setup_state zeros five POD per-search counters: native in the
// default build via zfish_thread_worker_reset_root_setup_state (main.zig), which
// writes them through the Worker offset map. The legacy oracle uses
// src/thread.cpp.

void zfish_thread_worker_set_root_moves(void* thread_ptr, const void* root_moves_ptr) {
    auto* thread = static_cast<Thread*>(thread_ptr);
    thread->worker_set_root_moves(*static_cast<const Search::RootMoves*>(root_moves_ptr));
}
#endif  // ZFISH_LEGACY_CPP_TARGET (legacy thread worker-op wrappers)

// set_root_position runs rootPos.set(fen, chess960, &rootState): native in the
// default build via zfish_thread_worker_set_root_position (main.zig), which
// dispatches to the native position set over the in-Worker rootPos/rootState.
// The legacy oracle uses src/thread.cpp.

// set_root_state assigns worker.rootState = value (POD StateInfo): native in the
// default build via zfish_thread_worker_set_root_state (main.zig), which memcpy's
// the 192-byte StateInfo through the probed rootState offset. The legacy oracle
// uses src/thread.cpp.

// set_tb_config assigns worker.tbConfig = Tablebases::Config{...}: native in the
// default build via zfish_thread_worker_set_tb_config (main.zig), which writes
// the four Config fields through the probed tbConfig offset. The legacy oracle
// uses src/thread.cpp.

#ifdef ZFISH_LEGACY_CPP_TARGET
std::uint64_t zfish_thread_nodes_searched(const void* thread_ptr) {
    return static_cast<const Thread*>(thread_ptr)->worker_nodes_searched();
}

std::uint64_t zfish_thread_tb_hits(const void* thread_ptr) {
    return static_cast<const Thread*>(thread_ptr)->worker_tb_hits();
}
#endif

// zfish_thread_fill_summary is native (main.zig): reads rootMoves[0]
// pv[0]/score/bound-flags/pv-size and rootDepth by offset. Bridge-only symbol.

// These five field resets are native (main.zig) in the default build; the legacy
// oracle keeps the C++ versions here, gated to the legacy target so the default
// link uses the Zig definitions without a duplicate symbol.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif

#ifdef ZFISH_LEGACY_CPP_TARGET
void zfish_threadpool_main_manager_clear_timeman(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->main_manager()->tm.clear();
}
#endif

}  // extern "C"
#endif

#endif  // ZFISH_LEGACY_CPP_TARGET


extern "C" {

void zfish_engine_numa_set_from_string(void*                numa_context_ptr,
                                       const unsigned char* text_ptr,
                                       std::size_t          text_len) {
#ifndef ZFISH_LEGACY_CPP_TARGET
    // M-FINAL cutover: single-node default build — the numa topology is fixed (one node from the
    // process affinity) and the display is native, so reconfiguring NumaPolicy is a no-op and
    // there is no C++ NumaReplicationContext to set.
    (void) numa_context_ptr;
    (void) text_ptr;
    (void) text_len;
#else
    auto& numa_context = *static_cast<NumaReplicationContext*>(numa_context_ptr);
    numa_context.set_numa_config(
      NumaConfig::from_string(std::string(reinterpret_cast<const char*>(text_ptr), text_len)));
#endif
}

// Stage-7 7.1: legacy oracle only -- the default build provides native-inert
// versions of these two from zig_src/main.zig (!legacy_target). Legacy keeps the
// real Tablebases:: probe from src/syzygy/tbprobe.cpp.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif  // ZFISH_LEGACY_CPP_TARGET

// Stage-7 7.1c: zfish_tbprobe_has_wdl_file / has_dtz_file deleted -- they were
// referenced only by the now-deleted dead zig_build/support/tbprobe.zig
// (never imported by either build) and by no src/ caller, so they were dead in
// both the default and legacy builds.

// Stage-7 7.1: legacy oracle only -- default build uses the native no-op from
// zig_src/main.zig (!legacy_target).
#ifdef ZFISH_LEGACY_CPP_TARGET
void zfish_engine_tablebases_init(const unsigned char* path_ptr, std::size_t path_len) {
    Tablebases::init(std::string(reinterpret_cast<const char*>(path_ptr), path_len));
}
#endif  // ZFISH_LEGACY_CPP_TARGET

// M-FINAL: ported to native operator new + zfish_accumulator_stack_reset (the AccumulatorStack
// ctor == zeroed + size 1) / operator delete (zig_src/main.zig). Legacy-oracle-only.
#ifdef ZFISH_LEGACY_CPP_TARGET
void* zfish_engine_accumulator_stack_create() {
    return new (std::nothrow) Eval::NNUE::AccumulatorStack();
}

void zfish_engine_accumulator_stack_destroy(void* stack_ptr) {
    delete static_cast<Eval::NNUE::AccumulatorStack*>(stack_ptr);
}
#endif

// M-FINAL: ported to native operator new + zfish_search_clear_refresh_cache (the AccumulatorCaches
// ctor == clear(network)) / operator delete (zig_src/main.zig). Legacy-oracle-only.
#ifdef ZFISH_LEGACY_CPP_TARGET
void* zfish_engine_accumulator_caches_create(const void* network_ptr) {
    return new (std::nothrow)
      Eval::NNUE::AccumulatorCaches(*static_cast<const Eval::NNUE::Network*>(network_ptr));
}

void zfish_engine_accumulator_caches_destroy(void* caches_ptr) {
    delete static_cast<Eval::NNUE::AccumulatorCaches*>(caches_ptr);
}
#endif

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
// Thin print primitive for native emit code: one mutex-guarded, flushed line
// through the same sync_cout/std::cout buffer the rest of the UCI output uses, so
// native and remaining-C++ output never interleave out of order.
void zfish_uci_print_line(const char* str, std::size_t len) {
    sync_cout << std::string_view(str, len) << sync_endl;
}
}

// M-FINAL cutover: the four search-update listeners write the LIVE updateContext via the
// accessor — &this->updateContext (inline) now, the heap-adjacent NativeEngine.update_context
// after the flip. updateContext IS live: the native search emit calls
// main_manager()->updates.onUpdateFull(...) (these std::functions) to record nodes / emit
// output, so they must land in the same UpdateContext the worker managers bind via the
// accessor. Behaviour-identical today.
static Search::SearchManager::UpdateContext& zfish_engine_update_context_ref(Engine* e) {
    return *static_cast<Search::SearchManager::UpdateContext*>(
      const_cast<void*>(zfish_engine_update_context_ptr(e)));
}
void Engine::set_on_update_no_moves(std::function<void(const Engine::InfoShort&)>&& f) {
    zfish_engine_update_context_ref(this).onUpdateNoMoves = std::move(f);
}

void Engine::set_on_update_full(std::function<void(const Engine::InfoFull&)>&& f) {
    zfish_engine_update_context_ref(this).onUpdateFull = std::move(f);
}

void Engine::set_on_iter(std::function<void(const Engine::InfoIter&)>&& f) {
    zfish_engine_update_context_ref(this).onIter = std::move(f);
}

void Engine::set_on_bestmove(std::function<void(std::string_view, std::string_view)>&& f) {
    zfish_engine_update_context_ref(this).onBestmove = std::move(f);
}

void Engine::set_on_verify_network(std::function<void(std::string_view)>&& f) {
#ifndef ZFISH_LEGACY_CPP_TARGET
    // M-FINAL cutover: write the NativeEngine's onVerifyNetwork std::function via the accessor.
    *static_cast<std::function<void(std::string_view)>*>(
      zfish_engine_onverifynetwork_ptr(this)) = std::move(f);
#else
    onVerifyNetwork = std::move(f);
#endif
}

extern "C" {
const char* zfish_engine_option_on_change(void*                engine_ptr,
                                          std::uint8_t         callback_kind,
                                          const unsigned char* value_ptr,
                                          std::size_t          value_len,
                                          int                  int_value);

// Zig-owned option model (default target only). The bridge registers every
// option here at OptionsMap::add and reads current values back by index; the C++
// currentValue stays the legacy oracle, so oracle-parity cross-checks the two.
std::size_t          zfish_optmodel_add(const unsigned char* name_ptr, std::size_t name_len,
                                        std::uint8_t kind, const unsigned char* default_ptr,
                                        std::size_t default_len, int min, int max);
std::uint8_t         zfish_optmodel_has_index(std::size_t idx);
int                  zfish_optmodel_int_by_index(std::size_t idx);
int                  zfish_optmodel_int_by_name(const unsigned char* name_ptr, std::size_t name_len);
std::size_t          zfish_optmodel_current_len(std::size_t idx);
const unsigned char* zfish_optmodel_current_ptr(std::size_t idx);
char*                zfish_optmodel_render();
void                 zfish_optmodel_publish_by_index(std::size_t idx, const unsigned char* value_ptr,
                                                     std::size_t value_len);
struct ZfishModelSetResult {
    std::uint8_t found;
    std::uint8_t accepted;
    std::uint8_t changed;
    std::uint8_t callback_kind;
    std::uint8_t kind;
    std::size_t  idx;
};
void zfish_optmodel_set_by_name(const unsigned char* name_ptr, std::size_t name_len,
                                const unsigned char* value_ptr, std::size_t value_len,
                                ZfishModelSetResult* out);
}

namespace {

#ifndef ZFISH_LEGACY_CPP_TARGET
// M-FINAL cutover: zfish_optmodel_kind/register are retired — registration now goes straight to the
// Zig model via zfish_engine_add_option (no C++ Option/OptionsMap::add path), so they had no callers
// and referenced the C++ Option type. Removed (frozen-type forward-decl prerequisite).


// M-FINAL cutover: a boolean option read sourced from the Zig model (default-build authority),
// so the remaining default get_options()[...] bool reads no longer touch the C++ OptionsMap.
bool zfish_opt_bool_native(const char* name) {
    const std::size_t len = std::char_traits<char>::length(name);
    return zfish_optmodel_int_by_name(reinterpret_cast<const unsigned char*>(name), len) != 0;
}

std::string zfish_optstore_read(std::size_t idx) {
    const std::size_t len = zfish_optmodel_current_len(idx);
    if (len == 0)
        return std::string{};
    return std::string(reinterpret_cast<const char*>(zfish_optmodel_current_ptr(idx)), len);
}

bool zfish_optstore_has(std::size_t idx) { return zfish_optmodel_has_index(idx) != 0; }
#endif

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

// M-FINAL cutover: legacy-only. The C++ Option on_change is only used by the legacy registration
// path (zfish_engine_add_option's #else builds a C++ Option with this callback). The default build
// registers straight into the Zig model and dispatches callbacks natively (zfish_engine_option_on_change
// via apply_setoption), so this — and its Option member access (idx/currentValue/int/string) — is
// dead in the default build. Removes the C++ Option access from the default build.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif  // ZFISH_LEGACY_CPP_TARGET

}  // namespace

extern "C" {
void        zfish_engine_init_body(void* engine_ptr);
// Harness H6 (engine_construct.zig): verify the constructed Engine graph.
void        zfish_verify_engine_graph(const void* engine_ptr);

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
#ifndef ZFISH_LEGACY_CPP_TARGET
    // M-FINAL cutover: register straight into the Zig option model (the default-build authority) —
    // NO C++ Option / OptionsMap is built. option_kind already equals the model kind (string=0,
    // check=1, spin=2, button=3); the default string is formatted exactly as the C++ Option ctor
    // would (bool→"true"/"false", spin→to_string, string→text, button→empty). The model derives
    // the on_change callback_kind from the option name (callbackKindForName), and the native
    // callback dispatch (zfish_engine_option_on_change) replaces the C++ Option's on_change — so
    // make_option_callback / the engine pointer / the passed callback_kind are unused here.
    (void) engine_ptr;
    (void) callback_kind;
    std::string default_str;
    switch (option_kind)
    {
    case kOptionTypeCheck:  default_str = (default_value != 0) ? "true" : "false"; break;
    case kOptionTypeSpin:   default_str = std::to_string(default_value); break;
    case kOptionTypeButton: default_str = ""; break;
    case kOptionTypeString: default_str.assign(reinterpret_cast<const char*>(default_ptr), default_len); break;
    default:                std::abort();
    }
    zfish_optmodel_add(name_ptr, name_len, option_kind,
                       reinterpret_cast<const unsigned char*>(default_str.data()), default_str.size(),
                       min_value, max_value);
#else
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
#endif
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

// M-FINAL (string-option readers): ported to native OptionsModel string reads (default
// build); these C++ OptionsMap[] reads are now legacy-oracle-only.
#ifdef ZFISH_LEGACY_CPP_TARGET
const char* zfish_engine_evalfile_text(const void* engine_ptr) {
    return alloc_c_string(std::string(static_cast<const Engine*>(engine_ptr)->get_options()["EvalFile"]));
}
#endif

extern "C" char* zfish_native_numa_config_string();  // native NumaConfig::to_string (main.zig)
const char* zfish_engine_numa_config_text(const void* engine_ptr) {
#ifndef ZFISH_LEGACY_CPP_TARGET
    // M-FINAL cutover: the default build has no C++ NumaReplicationContext — the single-node CPU
    // topology string is produced natively from the process affinity (main.zig).
    (void) engine_ptr;
    return zfish_native_numa_config_string();
#else
    auto* numa = static_cast<const NumaReplicationContext*>(
      zfish_engine_numa_context_ptr(const_cast<void*>(engine_ptr)));
    return alloc_c_string(numa->get_numa_config().to_string());
#endif
}

// zfish_engine_position_ptr, _options_ptr, _numa_context_ptr, _states_slot_ptr
// are native (main.zig), offset into the engine pointer via graph_layout.engine_off.

// M-FINAL cutover (states crack): native in the default build (zig_src/main.zig, StateList
// free+null). Legacy keeps the C++ unique_ptr::reset().
#ifdef ZFISH_LEGACY_CPP_TARGET
void zfish_engine_states_slot_reset(void* states_slot_ptr) {
    static_cast<StateListPtr*>(states_slot_ptr)->reset();
}
#endif

const void* zfish_engine_network_ptr(const void* engine_ptr) {
    // M-FINAL cutover: the native verify/eval/trace (network.zig) IGNORE this pointer — they emit
    // native architecture dims and serve weights from native storage. In the default build the
    // holder is a native stub (not a LazyNumaReplicated), so return the handle directly without
    // dereferencing (and without referencing the C++ Network type). Legacy keeps the real deref.
#ifdef ZFISH_LEGACY_CPP_TARGET
    auto* wrapper = static_cast<LazyNumaReplicatedSystemWide<NN::Network>*>(
      zfish_engine_network_replicated_ptr(const_cast<void*>(engine_ptr)));
    return wrapper->operator->();
#else
    return zfish_engine_network_replicated_ptr(const_cast<void*>(engine_ptr));
#endif
}

// zfish_engine_threads_ptr, _tt_ptr, _shared_hists_ptr, _network_replicated_ptr,
// _update_context_ptr are native (main.zig), offsetting into the engine pointer.

const void* zfish_numa_context_config(const void* numa_context_ptr) {
#ifndef ZFISH_LEGACY_CPP_TARGET
    // M-FINAL cutover: native stub context — the config handle is opaque (the single-node native
    // numa functions ignore it). Return it directly without referencing the C++ NumaConfig.
    return numa_context_ptr;
#else
    return &static_cast<const NumaReplicationContext*>(numa_context_ptr)->get_numa_config();
#endif
}

extern "C" void zfish_verify_shared_state_native(const void*, void*, void*, void*, void*, void*);

// REPORT-10 M-HUB: the live SharedState is now the NATIVE 40-byte struct
// (shared_state.zig), not the C++ Search::SharedState. C++ Search::SharedState was just
// 5 references with no methods, byte-identical to the native struct (long proven by the
// shadow verifier), so the workers bind the native one by reference unchanged. The
// member pointers stay the same objects until each member migrates to a native type.
extern "C" void* zfish_shared_state_native_create(void*, void*, void*, void*, void*);
extern "C" void  zfish_shared_state_native_destroy(void*);

void* zfish_search_shared_state_create(const void* options_ptr,
                                       void*       threads_ptr,
                                       void*       tt_ptr,
                                       void*       shared_hists_ptr,
                                       const void* network_ptr) {
    return zfish_shared_state_native_create(const_cast<void*>(options_ptr), threads_ptr, tt_ptr,
                                            shared_hists_ptr, const_cast<void*>(network_ptr));
}

void zfish_search_shared_state_destroy(void* shared_state_ptr) {
    zfish_shared_state_native_destroy(shared_state_ptr);
}

// M-FINAL (option readers): ported to native OptionsModel reads (zig_src/main.zig) in the
// default build; the C++ OptionsMap[] reads below are now legacy-oracle-only.
#ifdef ZFISH_LEGACY_CPP_TARGET
std::size_t zfish_engine_option_hash_value(const void* options_ptr) {
    return static_cast<std::size_t>((*static_cast<const OptionsMap*>(options_ptr))["Hash"]);
}
#endif

// M-FINAL: tt resize/clear ported to the native tt ops (zig_src/main.zig -> tt.zig) in the
// default build; these C++ TranspositionTable methods are now legacy-oracle-only.
#ifdef ZFISH_LEGACY_CPP_TARGET
void zfish_engine_tt_resize(void* tt_ptr, std::size_t mb, void* threads_ptr) {
    static_cast<TranspositionTable*>(tt_ptr)->resize(mb, *static_cast<ThreadPool*>(threads_ptr));
}

void zfish_engine_tt_clear(void* tt_ptr, void* threads_ptr) {
    static_cast<TranspositionTable*>(tt_ptr)->clear(*static_cast<ThreadPool*>(threads_ptr));
}
#endif

// M-FINAL: ported to native OptionsModel string read (default build); legacy-oracle-only.
#ifdef ZFISH_LEGACY_CPP_TARGET
char* zfish_engine_syzygy_path_text(const void* engine_ptr) {
    return alloc_c_string(std::string(static_cast<const Engine*>(engine_ptr)->get_options()["SyzygyPath"]));
}
#endif

// REPORT-10 M1: the live tt is the native side-allocated one (zfish_engine_tt_ptr).
// M-FINAL: hashfull ported to the native tt op (tt.zig) in the default build; legacy-only.
#ifdef ZFISH_LEGACY_CPP_TARGET
extern "C" void* zfish_engine_tt_ptr(void* engine_ptr);
int zfish_engine_tt_hashfull(const void* engine_ptr, int max_age) {
    return static_cast<const TranspositionTable*>(
             zfish_engine_tt_ptr(const_cast<void*>(engine_ptr)))
      ->hashfull(max_age);
}
#endif

// M-FINAL: ported to native OptionsModel read (default build); legacy-oracle-only.
#ifdef ZFISH_LEGACY_CPP_TARGET
std::uint8_t zfish_engine_chess960_enabled(const void* engine_ptr) {
    return static_cast<std::uint8_t>(static_cast<int>(static_cast<const Engine*>(engine_ptr)->get_options()["UCI_Chess960"]));
}
#endif

void zfish_engine_emit_verify_message(const void*          engine_ptr,
                                      const unsigned char* message_ptr,
                                      std::size_t          message_len) {
#ifndef ZFISH_LEGACY_CPP_TARGET
    // M-FINAL cutover: read the NativeEngine's onVerifyNetwork via the accessor.
    const auto& on_verify = *static_cast<const std::function<void(std::string_view)>*>(
      zfish_engine_onverifynetwork_ptr(const_cast<void*>(engine_ptr)));
#else
    const auto& on_verify = static_cast<const Engine*>(engine_ptr)->onVerifyNetwork;
#endif
    if (!on_verify)
        return;

    on_verify(std::string_view(reinterpret_cast<const char*>(message_ptr), message_len));
}
}

// Stage-6 6c: the Engine constructor is retired -- construction is now orchestrated
// natively by zfish_engine_construct_members (explicit per-member placement + the
// native init_body + the H6 verifier). The implicit Engine::Engine is no longer
// called in either build.

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
std::uint8_t  zfish_position_is_repetition_method(const void* pos_ptr, int ply);
std::uint8_t  zfish_position_is_draw_method(const void* pos_ptr, int ply);
std::uint8_t  zfish_position_has_repeated_method(const void* pos_ptr);
const char*   zfish_position_flip_fen(const unsigned char* fen_ptr, std::size_t fen_len);
const char*   zfish_position_set_method(void* pos_ptr, const unsigned char* fen_ptr,
                                        std::size_t fen_len, std::uint8_t is_chess960, void* st_ptr,
                                        std::size_t pos_size, std::size_t st_size);
std::uint8_t  zfish_position_legal_method(const void* pos_ptr, std::uint16_t move);
std::uint8_t  zfish_position_gives_check_method(const void* pos_ptr, std::uint16_t move);
std::uint8_t  zfish_position_pseudo_legal_method(const void* pos_ptr, std::uint16_t move);
void          zfish_position_undo_move_method(void* pos_ptr, std::uint16_t move);
void          zfish_position_do_move(void* pos_ptr, std::uint16_t move, void* new_st_ptr,
                                     std::uint8_t gives_check, void* dp_ptr, void* dts_ptr);
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

// M-FINAL cutover: get_options() resolves the OptionsMap via the accessor — &this->options
// (inline) now, the heap OptionsMap after the flip. Every options[...] / setoption caller
// funnels through here, so this one rewire covers them all. `this` is used only as the
// opaque engine pointer the accessor offsets/reads.
const OptionsMap& Engine::get_options() const {
    return *static_cast<const OptionsMap*>(zfish_engine_options_ptr(this));
}
OptionsMap& Engine::get_options() {
    return *static_cast<OptionsMap*>(const_cast<void*>(zfish_engine_options_ptr(this)));
}

// flip() flips the LIVE position (the native side block via the accessor), not the dead
// inline engine->pos. Untested on the gate (no flip command), so behaviour-neutral there.
void Engine::flip() { static_cast<Position*>(zfish_engine_position_ptr(this))->flip(); }

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

// M-FINAL cutover: dead in default (native search uses zfish_position_*_method directly).
#ifdef ZFISH_LEGACY_CPP_TARGET
bool Position::is_repetition(int ply) const {
    return zfish_position_is_repetition_method(this, ply) != 0;
}
#endif

#ifdef ZFISH_LEGACY_CPP_TARGET
bool Position::is_draw(int ply) const { return zfish_position_is_draw_method(this, ply) != 0; }
#endif

#ifdef ZFISH_LEGACY_CPP_TARGET
bool Position::has_repeated() const { return zfish_position_has_repeated_method(this) != 0; }
#endif

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

// gives_check is default-live (a C++ Position user computes it).
bool Position::gives_check(Move m) const {
    return zfish_position_gives_check_method(this, m.raw()) != 0;
}

#ifdef ZFISH_LEGACY_CPP_TARGET
bool Position::pseudo_legal(const Move m) const {
    return zfish_position_pseudo_legal_method(this, m.raw()) != 0;
}
#endif

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

// M-FINAL cutover (position-set port): native Position::set in the default build
// (zig_src/main.zig, position.zig FEN parser); legacy oracle keeps the C++ Position::set.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif

// M-FINAL cutover (position-set port): native in the default build (position.zig doMoveState);
// legacy oracle keeps the C++ Position::do_move.
#ifdef ZFISH_LEGACY_CPP_TARGET
extern "C" void zfish_position_do_move_state(void* pos_ptr, std::uint16_t move_raw, void* state_ptr) {
    static_cast<Position*>(pos_ptr)->do_move(Move(move_raw), *static_cast<StateInfo*>(state_ptr));
}
#endif

namespace {

}  // namespace

extern "C" {
void zfish_set_last_nodes_searched(std::uint64_t nodes);
}

// Stage-6 6c: the UCIEngine constructor is retired -- zfish_uci_engine_construct_at
// builds the engine + cli members directly and runs the listener registration
// below. init_search_update_listeners stays (called from construct_at).
void UCIEngine::init_search_update_listeners() {
    engine.set_on_iter([](const auto& i) { on_iter(i); });
    engine.set_on_update_no_moves([](const auto& i) { on_update_no_moves(i); });
    engine.set_on_update_full([this](const auto& i) {
        zfish_set_last_nodes_searched(i.nodes);
#ifndef ZFISH_LEGACY_CPP_TARGET
        const bool show_wdl = zfish_opt_bool_native("UCI_ShowWDL");
#else
        const bool show_wdl = engine.get_options()["UCI_ShowWDL"];
#endif
        on_update_full(i, show_wdl);
    });
    engine.set_on_bestmove([](const auto& bm, const auto& p) { on_bestmove(bm, p); });
    engine.set_on_verify_network([](const auto& s) { print_info_string(s); });
}

extern "C" {

// zfish_uci_cli_argc and zfish_uci_cli_arg_at are native (main.zig): they read
// cli.argc/argv by offset and bounds-check. Bridge-only symbols, no gating.

// zfish_uci_engine_ptr is native (main.zig): UCIEngine::engine is the first
// member (offset 0), so it returns the same pointer.

const char* zfish_engine_options_text_owner(const void* engine_ptr) {
#ifndef ZFISH_LEGACY_CPP_TARGET
    // Default build renders the listing from the Zig option model; the legacy
    // oracle renders from the C++ OptionsMap via operator<<.
    if (char* rendered = zfish_optmodel_render())
        return rendered;
#endif
    std::ostringstream options_stream;
    options_stream << static_cast<const Engine*>(engine_ptr)->get_options();
    return alloc_c_string(options_stream.str());
}

extern "C" void zfish_uci_set_quiet_mode(std::uint8_t quiet);

void zfish_uci_set_listener_mode(void* uci_ptr, std::uint8_t quiet_mode) {
    // Mirror the mode into the native flag the native emit functions read.
    zfish_uci_set_quiet_mode(quiet_mode);
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

#ifndef ZFISH_LEGACY_CPP_TARGET
    // Default build: the Zig option model is the write authority. Apply the
    // assignment to the model, then fire the on_change callback exactly as the
    // C++ Option operator= would -- spin/check relay to_string(int(option)) and
    // the int, string relays the current value, button relays nothing -- and
    // route any returned message through the OptionsMap info listener.
    const std::string name(reinterpret_cast<const char*>(name_ptr), name_len);
    const std::string value = has_value != 0
                                ? std::string(reinterpret_cast<const char*>(value_ptr), value_len)
                                : std::string{};

    ZfishModelSetResult res;
    zfish_optmodel_set_by_name(reinterpret_cast<const unsigned char*>(name.data()), name.size(),
                               reinterpret_cast<const unsigned char*>(value.data()), value.size(),
                               &res);

    if (!res.found)
    {
        sync_cout << "No such option: " << name << sync_endl;
        return;
    }

    if (res.accepted && res.callback_kind != kOptionCallbackNone)
    {
        std::string relay_value;
        int         relay_int = 0;
        if (res.kind == kOptionTypeCheck || res.kind == kOptionTypeSpin)
        {
            relay_int   = zfish_optmodel_int_by_index(res.idx);
            relay_value = std::to_string(relay_int);
        }
        else if (res.kind == kOptionTypeString)
        {
            relay_value = zfish_optstore_read(res.idx);
        }

        auto ret = take_optional_c_string(zfish_engine_option_on_change(
          engine, res.callback_kind, reinterpret_cast<const unsigned char*>(relay_value.data()),
          relay_value.size(), relay_int));

        // M-FINAL cutover: emit the callback's info message directly (what the C++ OptionsMap info
        // listener did), so apply_setoption no longer touches the C++ OptionsMap. The native model
        // is the option authority; the OptionsMap is now an empty stub in the default build.
        if (ret)
            UCIEngine::print_info_string(*ret);
    }
#else
    std::ostringstream command;
    command << "name " << std::string(reinterpret_cast<const char*>(name_ptr), name_len);
    if (has_value != 0)
        command << " value " << std::string(reinterpret_cast<const char*>(value_ptr), value_len);

    std::istringstream is(command.str());
    engine->get_options().setoption(is);
#endif
}

// Recursive perft subtree counter, exported from zig_src/main.zig.
extern "C" std::uint64_t zfish_perft_subtree(void* pos, int depth);

std::uint64_t zfish_engine_perft_owner(void* engine_ptr, int depth) {
    auto* engine = static_cast<Engine*>(engine_ptr);
    zfish_engine_verify_network_method(engine);

    // REPORT-10 pos migration: read the live (native side-allocated) pos via the
    // accessor, not the dead C++ engine->pos member.
    const char* rendered_fen = zfish_engine_fen(zfish_engine_position_ptr(engine_ptr));
    if (!rendered_fen)
        std::abort();

    const std::string fen(rendered_fen);
    std::free(const_cast<char*>(rendered_fen));

#ifndef ZFISH_LEGACY_CPP_TARGET
    const bool chess960 = zfish_opt_bool_native("UCI_Chess960");
#else
    const bool chess960 = engine->get_options()["UCI_Chess960"];
#endif

#ifndef ZFISH_LEGACY_CPP_TARGET
    // The recursive subtree count runs in Zig (zfish_perft_subtree); the root
    // divide loop stays here so the per-move output and MoveList<LEGAL> ordering
    // are byte-identical to the original. This mirrors Benchmark::perft<true>.
    Position  p;
    StateInfo st;
    p.set(fen, chess960, &st);

    std::uint64_t nodes = 0;
    for (const auto& m : MoveList<LEGAL>(p))
    {
        std::uint64_t cnt;
        if (depth <= 1)
        {
            cnt = 1;
            nodes += 1;
        }
        else
        {
            StateInfo si;
            p.do_move(m, si);
            cnt = zfish_perft_subtree(&p, depth - 1);
            nodes += cnt;
            p.undo_move(m);
        }
        sync_cout << UCIEngine::move(m, p.is_chess960()) << ": " << cnt << sync_endl;
    }
#else
    const auto nodes = Benchmark::perft(fen, depth, chess960);
#endif

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

// M-FINAL (limits readers): ported to native Zig offset reads (zig_src/main.zig) in the
// default build; these C++ defs are now legacy-oracle-only (else duplicate symbols vs the
// Zig exports). Pure reads, no allocation — valgrind-clean across the boundary.
#ifdef ZFISH_LEGACY_CPP_TARGET
std::uint8_t zfish_limits_ponder_mode(const void* limits_ptr) {
    return static_cast<const Search::LimitsType*>(limits_ptr)->ponderMode ? 1 : 0;
}

std::size_t zfish_limits_perft_value(const void* limits_ptr) {
    return static_cast<std::size_t>(static_cast<const Search::LimitsType*>(limits_ptr)->perft);
}

std::size_t zfish_limits_searchmove_count(const void* limits_ptr) {
    return static_cast<const Search::LimitsType*>(limits_ptr)->searchmoves.size();
}
#endif

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

// Stage 5 support: the native std::vector<RootMove> copy-assign (set_root_moves)
// must (re)allocate its element buffer with ::operator new so the C++ ~vector
// frees it with the matching ::operator delete. RootMove is standard-layout POD
// (PVMoves is a fixed Move[] array), so the assign is one memcpy of count*stride.
extern "C" std::size_t zfish_root_move_sizeof(void) { return sizeof(Search::RootMove); }
extern "C" void* zfish_operator_new(std::size_t n) { return ::operator new(n); }
extern "C" void  zfish_operator_delete(void* p) { ::operator delete(p); }

// Stage 5: native set_limits copies only the POD tail of LimitsType (everything
// after the leading std::vector<std::string> searchmoves member). searchmoves is
// vestigial in the Worker copy -- the search filters root moves from the SOURCE
// limits at root setup, never from worker.limits -- so the native copy leaves the
// Worker's searchmoves vector empty (valid for ~vector). sizeof + the searchmoves
// member span come from C++ so the offsets can't drift.
// M-FINAL: the LimitsType layout anchors are now native constants (zig_src/main.zig +
// graph_layout.limits_off); these C++ sizeof(...) source-of-truth defs are kept legacy-only.
#ifdef ZFISH_LEGACY_CPP_TARGET
extern "C" std::size_t zfish_limits_sizeof(void) { return sizeof(Search::LimitsType); }
extern "C" std::size_t zfish_limits_searchmoves_bytes(void) {
    return sizeof(std::vector<std::string>);
}
#endif

// zfish_threadpool_bound_node_count and zfish_threadpool_bound_node_at are native
// (main.zig): they read the boundThreadToNumaNode vector span / element by offset.
// Bridge-only symbols, no legacy gating needed.

// zfish_numa_context_node_count is native (main.zig): NumaReplicationContext has
// config as its first member (no vtable), so the context pointer is the
// NumaConfig and it delegates to the native node-count. Bridge-only, no gating.

// zfish_numa_context_cpus_in_node is native (main.zig): it reads nodes[node].size()
// (the std::set element count at +40) from config (at context offset 0).
// Bridge-only symbol, no gating.

// M-FINAL (option readers): ported to native OptionsModel reads (default build); these C++
// OptionsMap[] reads are now legacy-oracle-only.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif

// M-FINAL: ported to native operator new/delete of a zeroed position_size block
// (zig_src/main.zig); Position is POD with a trivial defaulted ctor. Legacy-oracle-only.
#ifdef ZFISH_LEGACY_CPP_TARGET
void* zfish_position_create() { return new Position(); }

void zfish_position_destroy(void* pos_ptr) { delete static_cast<Position*>(pos_ptr); }
#endif

// Stage-7 7.2d: legacy-only. The default build resets the pool for reconfigure via
// the native zfish_native_threadpool_clear (thread.zig comptime-prunes the legacy
// branch that called this).
#ifdef ZFISH_LEGACY_CPP_TARGET
void zfish_threadpool_reset_for_reconfigure(void* pool_ptr) {
    auto* pool = static_cast<ThreadPool*>(pool_ptr);
    pool->threads.clear();
    pool->boundThreadToNumaNode.clear();
}
#endif  // ZFISH_LEGACY_CPP_TARGET

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

// M-FINAL (option reader): ported to native OptionsModel read (default build); legacy only.
#ifdef ZFISH_LEGACY_CPP_TARGET
std::size_t zfish_shared_state_threads_value(const void* shared_state_ptr) {
    const auto& shared_state = *static_cast<const Search::SharedState*>(shared_state_ptr);
    return static_cast<std::size_t>(shared_state.options["Threads"]);
}
#endif

// M-FINAL: ported to native OptionsModel string read + compare (default build); legacy only.
#ifdef ZFISH_LEGACY_CPP_TARGET
std::uint8_t zfish_shared_state_numa_policy_mode(const void* shared_state_ptr) {
    const auto&       shared_state = *static_cast<const Search::SharedState*>(shared_state_ptr);
    const std::string numa_policy(shared_state.options["NumaPolicy"]);

    if (numa_policy == "none")
        return 0;
    if (numa_policy == "auto")
        return 1;
    return 2;
}
#endif

// Native SharedHistoriesMap ops (zig_src/main.zig). REPORT-10 sharedHists migration: in
// the default build the engine `sharedHists` member is a native SharedHistoriesMap (not a
// std::map), reached via SharedState.sharedHistories; the C++ std::map clear/try_emplace/
// at flip to these native calls. The legacy oracle keeps the real std::map (its C++ Worker
// ctor calls std::map::at), so these are referenced in the default branch only.
extern "C" void  zfish_native_shared_histories_clear(void* map);
extern "C" void  zfish_native_shared_histories_insert(void* map, std::size_t numa_index,
                                                      std::size_t size);
extern "C" void* zfish_native_shared_histories_at(void* map, std::size_t numa_index);

void zfish_shared_state_clear_histories(const void* shared_state_ptr) {
    const auto& shared_state = *static_cast<const Search::SharedState*>(shared_state_ptr);
#ifdef ZFISH_LEGACY_CPP_TARGET
    shared_state.sharedHistories.clear();
#else
    // SharedState.sharedHistories points at the native SharedHistoriesMap; &ref yields
    // that native map pointer (the stored reference value).
    zfish_native_shared_histories_clear(
      const_cast<void*>(reinterpret_cast<const void*>(&shared_state.sharedHistories)));
#endif
}

// Native-graph cut flip fire 2: shadow verifier (zig_src/main.zig). Diffs the native
// SharedHistories sizing against the C++ try_emplace result; false = mismatch. Legacy
// oracle only (the default build's node IS the native one — nothing to diff against).
extern "C" bool zfish_shadow_verify_shared_histories(const void* shared, std::size_t thread_count);

void zfish_shared_state_insert_history(const void*  shared_state_ptr,
                                       const void*  numa_config_ptr,
                                       std::size_t  numa_index,
                                       std::size_t  size,
                                       std::uint8_t do_bind) {
    const auto& shared_state = *static_cast<const Search::SharedState*>(shared_state_ptr);

#ifdef ZFISH_LEGACY_CPP_TARGET
    const auto& numa_config = *static_cast<const NumaConfig*>(numa_config_ptr);
    auto insert = [&]() { shared_state.sharedHistories.try_emplace(numa_index, size); };
    if (do_bind != 0)
        numa_config.execute_on_numa_node(numa_index, insert);
    else
        insert();

    // Shadow-verify the native sizing logic against the freshly built C++ node. The
    // native builder (constructSharedHistories) is unwired in legacy; this proves its
    // sizing tracks the oracle at every engine construction. Loud abort on divergence.
    if (!zfish_shadow_verify_shared_histories(&shared_state.sharedHistories.at(numa_index), size)) {
        std::fprintf(stderr,
                     "zfish: shared_histories shadow verify failed (numa=%zu size=%zu)\n",
                     numa_index, size);
        std::abort();
    }
#else
    // M-FINAL cutover: the default build is single-node, so threads are never bound (do_bind is
    // always 0) and no NumaConfig / execute_on_numa_node is needed — insert directly into the
    // native SharedHistoriesMap. Removes the C++ NumaConfig reference from the default build.
    (void) numa_config_ptr;
    (void) do_bind;
    void* native_map =
      const_cast<void*>(reinterpret_cast<const void*>(&shared_state.sharedHistories));
    zfish_native_shared_histories_insert(native_map, numa_index, size);
#endif
}

std::uint8_t zfish_numa_config_suggests_binding_threads(const void* numa_config_ptr,
                                                        std::size_t requested) {
#ifndef ZFISH_LEGACY_CPP_TARGET
    // M-FINAL cutover: single-node default build never binds threads (one numa node), so this is
    // a native constant 0 — no C++ NumaConfig read. Legacy keeps the real topology query.
    (void) numa_config_ptr;
    (void) requested;
    return 0;
#else
    return static_cast<const NumaConfig*>(numa_config_ptr)->suggests_binding_threads(requested)
             ? std::uint8_t{1}
             : std::uint8_t{0};
#endif
}

std::size_t zfish_numa_config_distribute_threads_among_nodes(const void* numa_config_ptr,
                                                             std::size_t requested,
                                                             std::size_t* out_nodes) {
#ifndef ZFISH_LEGACY_CPP_TARGET
    // M-FINAL cutover: single-node default build — all requested threads map to node 0 (one numa
    // node). Dead on this path anyway (binding is never suggested), but kept NumaConfig-free.
    (void) numa_config_ptr;
    if (out_nodes)
        for (std::size_t i = 0; i < requested; ++i)
            out_nodes[i] = 0;
    return 1;
#else
    const auto distribution =
      static_cast<const NumaConfig*>(numa_config_ptr)->distribute_threads_among_numa_nodes(
        requested);
    if (out_nodes)
        std::copy(distribution.begin(), distribution.end(), out_nodes);
    return distribution.size();
#endif
}

// num_numa_nodes() == nodes.size(): now native in both builds via the Zig export
// zfish_numa_config_node_count (main.zig), which reads the nodes vector span by
// offset. The NumaConfig layout is identical in the default and legacy targets,
// so no C++ body is needed here.

void zfish_numa_config_execute_on_numa_node(const void*       numa_config_ptr,
                                            std::size_t       numa_index,
                                            ZfishOpaqueCallback callback,
                                            void*             context) {
#ifndef ZFISH_LEGACY_CPP_TARGET
    // M-FINAL cutover: single-node default build — no NUMA pinning, just run the callback on the
    // current (only) node. Dead on the live path (binding never suggested); kept NumaConfig-free.
    (void) numa_config_ptr;
    (void) numa_index;
    callback(context);
#else
    const auto& numa_config = *static_cast<const NumaConfig*>(numa_config_ptr);
    numa_config.execute_on_numa_node(numa_index, [&]() { callback(context); });
#endif
}

// Layer 2 (stage-4 native thread runtime): mint an ISearchManager for a native
// Thread -- a SearchManager for the main thread (id 0), a NullSearchManager for
// workers -- returned as a raw owning pointer the way std::make_unique<>().release()
// does in the C++ add_main_thread/add_worker_thread. The native ThreadBuilder
// (layer 4) hands this to zfish_worker_construct_full as the worker's `manager`.
// This is the thin C++ residue (Option A): SearchManager keeps its vtable + tm +
// UpdateContext; its data fields are already read/written natively by offset.
// M-FINAL / M-SM: the default build mints the manager natively (zig_src/main.zig
// zfishMakeSearchManager: a raw operator-new'd buffer, no C++ SearchManager type / vtable),
// and tears down the Worker natively (no virtual `delete manager`). This C++ version --
// std::make_unique<Search::SearchManager> with its vtable -- is now legacy-oracle-only.
#ifdef ZFISH_LEGACY_CPP_TARGET
extern "C" void* zfish_make_search_manager(const void* update_context_ptr,
                                           std::uint8_t is_main) {
    if (is_main != 0)
    {
        const auto& uc =
          *static_cast<const Search::SearchManager::UpdateContext*>(update_context_ptr);
        return std::make_unique<Search::SearchManager>(uc).release();
    }
    return std::make_unique<Search::NullSearchManager>().release();
}
#endif
// Forward decl: in the default build this resolves to the native Zig export (above);
// the C++ native_worker_build (below) calls it to mint the worker's manager.
extern "C" void* zfish_make_search_manager(const void* update_context_ptr, std::uint8_t is_main);

// Layer 4 (stage-4 native thread runtime): the native_threadpool.set ThreadBuilder
// callback. Resolves the SharedState members for thread `idx`, large-page-allocs +
// natively constructs the Worker (the same zfish_worker_construct_full the C++
// Thread ctor uses), mints the SearchManager, and writes the Worker at thread+8
// (the worker@8 layout contract). Single-node host: numaIndex 0, idxInNuma == idx,
// totalNuma passed in via ctx.total. Replaces the per-thread C++ Thread ctor.
#ifndef ZFISH_LEGACY_CPP_TARGET
extern "C" {
struct ZfishWorkerBuildCtx {
    void*       shared_state;
    const void* update_context;
    std::size_t total;
};
void zfish_native_worker_build(void* ctx_ptr, std::size_t idx, void* thread) {
    auto* ctx = static_cast<ZfishWorkerBuildCtx*>(ctx_ptr);
    auto& ss  = *static_cast<Search::SharedState*>(ctx->shared_state);
    void* manager = zfish_make_search_manager(ctx->update_context, idx == 0 ? 1 : 0);
    void* raw = aligned_large_pages_alloc(sizeof(Search::Worker));
    zfish_worker_construct_full(
      raw,
      // Native SharedHistoriesMap.at(0): SharedState.sharedHistories is the native map in
      // the default build (REPORT-10 sharedHists migration). &ref yields the map pointer.
      reinterpret_cast<std::size_t>(
        zfish_native_shared_histories_at(reinterpret_cast<void*>(&ss.sharedHistories), 0)),
      reinterpret_cast<std::size_t>(&ss.options),
      reinterpret_cast<std::size_t>(&ss.threads),
      reinterpret_cast<std::size_t>(&ss.tt),
      reinterpret_cast<std::size_t>(&ss.network),
      reinterpret_cast<std::size_t>(manager),
      idx, idx, ctx->total, 0);
    *reinterpret_cast<void**>(static_cast<char*>(thread) + 8) = raw; // worker@8
}
// M-FINAL / M-SM: zfish_native_worker_destroy is now native (zig_src/main.zig) -- it frees
// the rootMoves buffer + the manager by offset + returns the large-page block, reproducing
// ~Worker WITHOUT the virtual `delete manager` (the SearchManager vtable wall). So the
// default build no longer runs ~Worker here; only the C++ worker_build remains C++.
}
#else  // ZFISH_LEGACY_CPP_TARGET
// The legacy oracle build keeps the C++ Thread vehicle, so the native worker
// build/destroy are never invoked at runtime (thread.zig selects the vehicle at
// COMPTIME via target_flags.legacy_target). They must still LINK because the
// shared native ThreadPool references them -- provide abort stubs.
extern "C" void zfish_native_worker_build(void*, std::size_t, void*) {
    std::abort();
}
extern "C" void zfish_native_worker_destroy(void*) {
    std::abort();
}
#endif // ZFISH_LEGACY_CPP_TARGET

// Stage-7 7.2e: zfish_is_legacy_build() retired. The shared thread module used to
// branch on it at RUNTIME; since 7.2b thread.zig is built per-exe and gates on the
// comptime target_flags.legacy_target, so this runtime probe has no callers in
// either build.

// Stage-7 7.2d: legacy-only thread-creation wrappers (build C++ Thread objects via
// make_unique<Thread>). The default build creates native Threads through
// native_threadpool.zig (zfish_native_threadpool_set / zfish_native_worker_build).
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif  // ZFISH_LEGACY_CPP_TARGET (legacy thread-creation wrappers)

struct ZfishPendingStateListStorage {
    StateListPtr states;

    ZfishPendingStateListStorage() :
        states(new std::deque<StateInfo>(1)) {}
};

// M-FINAL cutover (states crack): native StateList storage/adopt in the default build
// (zig_src/main.zig + state_list.zig). Legacy oracle keeps the C++ deque<StateInfo> storage.
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif  // ZFISH_LEGACY_CPP_TARGET (states crack)

// M-FINAL cutover (thread cluster): native in the default build (zig_src/main.zig, setupStates
// null-check by offset). Legacy oracle keeps the C++ ThreadPool::setupStates access.
#ifdef ZFISH_LEGACY_CPP_TARGET
std::uint8_t zfish_threadpool_has_setup_states(const void* pool_ptr) {
    const auto& pool = *static_cast<const ThreadPool*>(pool_ptr);
    return pool.setupStates ? std::uint8_t{1} : std::uint8_t{0};
}
#endif

// M-FINAL cutover (states crack): native in the default build (zig_src/main.zig, StateList.back()
// by offset). Legacy keeps the C++ deque back().
#ifdef ZFISH_LEGACY_CPP_TARGET
const void* zfish_threadpool_setup_state_back(const void* pool_ptr) {
    const auto& pool = *static_cast<const ThreadPool*>(pool_ptr);
    if (!pool.setupStates)
        return nullptr;

    return &pool.setupStates->back();
}
#endif

// M-FINAL cutover: the NumaPolicy option handlers. In the default build the numa context is a
// native stub (no C++ NumaConfig) and the topology is fixed single-node (display is native), so
// reconfiguring it is a no-op — and they MUST NOT cast/write the stub (heap corruption). Legacy
// keeps the real set_numa_config (its C++ NumaReplicationContext drives the oracle's threads).
#ifndef ZFISH_LEGACY_CPP_TARGET
void zfish_numa_context_set_system(void*) {}
void zfish_numa_context_set_hardware(void*) {}
void zfish_numa_context_set_none(void*) {}
#else
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
#endif

}

bool Tune::update_on_last;
OptionsMap* Tune::options;

// M-FINAL cutover: the C++ OptionsMap methods are dead in the default build — registration goes
// straight to the Zig model (zfish_engine_add_option), reads are model-routed, the info listener was
// retired, Tune is inert, and the OptionsMap member is a malloc(1) stub. Legacy-only; the default
// build never calls them (verified by the link). Removes the C++ OptionsMap member access from the
// default build (a frozen-type forward-decl prerequisite).
#ifdef ZFISH_LEGACY_CPP_TARGET
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
#endif  // ZFISH_LEGACY_CPP_TARGET

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
#ifndef ZFISH_LEGACY_CPP_TARGET
    const std::string val = zfish_optstore_has(idx) ? zfish_optstore_read(idx) : currentValue;
#else
    const std::string& val = currentValue;
#endif
    return type == "spin" ? std::stoi(val) : val == "true";
}

Option::operator std::string() const {
    assert(type == "string");
#ifndef ZFISH_LEGACY_CPP_TARGET
    return zfish_optstore_has(idx) ? zfish_optstore_read(idx) : currentValue;
#else
    return currentValue;
#endif
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

// M-FINAL cutover: Tune (SPSA) is inactive in a release build — no live TUNE() macros, so the tune
// list is empty and these Entry<int> methods are never called. In the default build they are inert,
// so they do not reference the C++ OptionsMap (add/count/operator[]) or Option — breaking the
// OptionsMap↔Tune↔Option coupling so the OptionsMap methods can be retired. Legacy keeps the SPSA
// bridge to the real C++ OptionsMap.
template<>
void Tune::Entry<int>::init_option() {
#ifdef ZFISH_LEGACY_CPP_TARGET
    make_option(options, name, value, range);
#endif
}

template<>
void Tune::Entry<int>::read_option() {
#ifdef ZFISH_LEGACY_CPP_TARGET
    if (options->count(name))
        value = int((*options)[name]);
#endif
}

template<>
void Tune::Entry<Tune::PostUpdate>::init_option() {}

template<>
void Tune::Entry<Tune::PostUpdate>::read_option() {
    value();
}

void Tune::read_results() { /* ...insert your values here... */ }

}  // namespace Stockfish

// --- Stage-6 (Annex A) milestone 6c: native-orchestrated Engine construction -----
// Type-deducing placement-construct helper: builds an object of the slot's own
// declared type in place, so the C++ compiler computes every member offset (no
// raw-offset arithmetic). Handles const members (binaryDirectory) via remove_const.
namespace {
template <class T, class... A>
inline void zfish_place(T& slot, A&&... args) {
    using U = std::remove_const_t<T>;
    ::new (const_cast<U*>(&slot)) U(std::forward<A>(args)...);
}
}  // namespace

// Explicit per-member construction of the Engine sub-object, replacing the implicit
// bridge Engine::Engine member-init list. Members are placement-constructed in
// DECLARATION order via named member access (#define private public, top of file,
// grants access). This reproduces the original init list (binaryDirectory,
// numaContext, states, network) plus the default-constructed members (pos, options,
// threads, tt, updateContext, onVerifyNetwork, sharedHists), then runs the native
// init_body (options + start position + thread sizing) and the H6 graph verifier --
// exactly the work the C++ ctor body did. Ordering matches the C++ object model:
// numaContext before network (network captures it by ref), binaryDirectory before
// network (get_default_network reads it), options/init_body after the members.
// Native-graph cut flip fire 3: network-holder shadow verifier (zig_src/main.zig).
// Diffs the native model of the LazyNumaReplicatedSystemWide replica count against the
// live one. elem_size = sizeof(SystemWideSharedConstant<Network>) (the fat vector
// element stride), taken from this build so the native size() math is pinned to it.
extern "C" bool zfish_shadow_verify_network_holder(const void* network,
                                                   std::size_t expected_nodes,
                                                   std::size_t elem_size);
// Flip fire 4: whole-graph native owned-member construction exercise (zig_src/main.zig).
extern "C" bool zfish_shadow_construct_engine_graph();

// ---------------------------------------------------------------------------
// M-FINAL cutover (NATIVE_ENGINE_CUTOVER.md): standalone heap allocators for the
// engine's interim-C++ members. The native engine (zig_src) owns each member as an
// explicitly-freed heap object that it points at, instead of an inline sub-object of
// a C++ Engine -- so no C++ ~Engine/~UCIEngine ever runs and the ~Engine/~ThreadPool
// coupling dissolves. These mint/destroy the individual C++ member objects the native
// container references; each member later ports to a native type incrementally green.
// Default build only (the legacy oracle keeps the inline C++ Engine + its ctor/dtor).
// Unused until the construct/destruct flip wires them; additive + behaviour-neutral.
#ifndef ZFISH_LEGACY_CPP_TARGET
extern "C" {

// numaContext: NumaReplicationContext(NumaConfig::from_system(DefaultNumaPolicy)).
void* zfish_member_numa_context_new() {
    // M-FINAL cutover: native single-node numa context stub. The default build is single-node
    // (multi-node dropped) and never reads a C++ NumaConfig — node_count/suggests/to_string are
    // native, the thread-distribution functions are NumaConfig-free, and binding never happens.
    // So NO C++ NumaReplicationContext is constructed; a minimal heap handle suffices.
    return std::malloc(1);
}
void zfish_member_numa_context_delete(void* p) { std::free(p); }

// threads: a default-constructed ThreadPool (its vector is populated later by
// zfish_native_threadpool_set; setupStates is adopted at search start).
// M-FINAL cutover: native allocation of the ThreadPool storage — no C++ ctor/dtor. ThreadPool's
// ctor is `ThreadPool(){}` and its members (atomic_bool stop/increaseDepth, unique_ptr setupStates,
// vector threads/boundThreadToNumaNode) are all zero-init-valid with no vtable/mutex, so a calloc'd
// buffer equals a value-initialized ThreadPool. The threads vector is native-managed
// (native_threadpool.zig writes begin/end by offset); teardown runs zfish_native_threadpool_clear
// first (drains, joins, destroys threads, nulls the vector), so ~ThreadPool would be a no-op —
// free() is equivalent. (sizeof stays until the frozen-type forward-decl endgame swaps it native.)
void* zfish_member_threadpool_new() { return std::calloc(1, sizeof(Stockfish::ThreadPool)); }
void  zfish_member_threadpool_delete(void* p) { std::free(p); }

// options: a default-constructed OptionsMap. Stays the interim registration vehicle
// (OptionsMap::add populates the native OptionsModel + the setoption relay), so it is
// still the path that feeds the native store until options ports fully native.
// M-FINAL cutover: native single-option-store stub. The default build's option authority is the
// Zig OptionsModel (option.zig) for registration, reads, writes, render, and callbacks; the C++
// OptionsMap is never populated, read, or rendered, and its info listener was retired. So NO C++
// OptionsMap is constructed — a minimal heap handle suffices (get_options() returns it but nothing
// dereferences it; Tune::init only stores the pointer, its tune list is empty in a release build).
void* zfish_member_options_new() { return std::malloc(1); }
void  zfish_member_options_delete(void* p) { std::free(p); }

// updateContext: placement-construct/destruct a Search::SearchManager::UpdateContext in
// the native engine's inline 240B slot. LIVE — the native search emit calls its
// onUpdateFull/onBestmove/etc (set by init_search_update_listeners), and the worker
// managers bind &update_context via zfish_engine_update_context_ptr. Held inline (not
// a separate heap alloc) so the accessor address is stable for the engine's lifetime.
void zfish_member_update_context_construct(void* p) {
    ::new (p) Stockfish::Search::SearchManager::UpdateContext();
}
void zfish_member_update_context_destruct(void* p) {
    using UC = Stockfish::Search::SearchManager::UpdateContext;
    static_cast<UC*>(p)->~UC();
}

// onVerifyNetwork: an empty std::function<void(std::string_view)>, placement-constructed
// in the native engine's inline slot. set_on_verify_network assigns it (print_info_string
// interactive / no-op quiet); zfish_engine_emit_verify_message invokes it. Held inline so
// the accessor address is stable.
using ZfishVerifyNetworkFn = std::function<void(std::string_view)>;
void zfish_member_verify_network_fn_construct(void* p) { ::new (p) ZfishVerifyNetworkFn(); }
void zfish_member_verify_network_fn_destruct(void* p) {
    static_cast<ZfishVerifyNetworkFn*>(p)->~ZfishVerifyNetworkFn();
}

// states: StateListPtr(new std::deque<StateInfo>(1)) on the heap. Returned as the
// raw deque pointer; the native engine holds it in its `states` slot (a unique_ptr
// equivalent) and it is std::move'd into pool.setupStates at search start.
void* zfish_member_states_new() {
    return new std::deque<Stockfish::StateInfo>(1);
}
void zfish_member_states_delete(void* p) {
    delete static_cast<std::deque<Stockfish::StateInfo>*>(p);
}
void* zfish_member_states_back(void* p) {
    return &static_cast<std::deque<Stockfish::StateInfo>*>(p)->back();
}

// network: LazyNumaReplicatedSystemWide<Network>(numaContext, get_default_network()).
// get_default_network() == make_unique<Network>(EvalFile{default}) + load(binaryDir).
// The native NNUE load entry (Zig-owned, main.zig). Declared here for the native holder below.
void zfish_network_load(void*, const unsigned char*, std::size_t, const unsigned char*, std::size_t);
void* zfish_member_network_new(void* numa_context, const char* binary_dir,
                               std::size_t binary_dir_len) {
    // M-FINAL cutover: native single-node network holder. The default build serves all NNUE
    // weights from native storage (network.zig) and NEVER dereferences this handle — the worker
    // network resolver returns native_ft_ptr, the eval/verify read native state, and nothing
    // indexes network[token]. So the holder is a minimal heap handle: NO C++ Network and NO
    // LazyNumaReplicatedSystemWide<Network> is constructed (removes the C++ Network type + the
    // 106 MB master from the default build). The native NNUE load (populates the Zig-owned
    // storage) is triggered here, as the old net->load() did. numa_context is unused (single node).
    (void) numa_context;
    void* holder = std::malloc(1);
    zfish_network_load(holder,
                       reinterpret_cast<const unsigned char*>(binary_dir), binary_dir_len,
                       reinterpret_cast<const unsigned char*>(""), 0);
    return holder;
}
void zfish_member_network_delete(void* p) { std::free(p); }

}  // extern "C"
#endif  // !ZFISH_LEGACY_CPP_TARGET

// M-FINAL cutover: legacy-oracle-only — the default build constructs a NativeEngine via
// zfish_native_engine_construct_members instead of placement-constructing this C++ Engine.
#ifdef ZFISH_LEGACY_CPP_TARGET
static void zfish_engine_construct_members(Stockfish::Engine* e, const char* argv0) {
    using namespace Stockfish;
    zfish_place(e->binaryDirectory, CommandLine::get_binary_directory(argv0));
    zfish_place(e->numaContext, NumaConfig::from_system(DefaultNumaPolicy));
    zfish_place(e->pos);
    zfish_place(e->states, new std::deque<StateInfo>(1));
    zfish_place(e->options);
    zfish_place(e->threads);
    zfish_place(e->tt);
    zfish_place(e->network, e->numaContext, e->get_default_network());
    // Shadow-verify the native holder model against the freshly built C++ holder: its
    // replica count must equal its own configured node count. Loud abort on divergence.
    if (!zfish_shadow_verify_network_holder(
            &e->network, e->network.get_numa_config().num_numa_nodes(),
            sizeof(SystemWideSharedConstant<Eval::NNUE::Network>))) {
        std::fprintf(stderr, "zfish: network holder shadow verify failed\n");
        std::abort();
    }
    zfish_place(e->updateContext);
    zfish_place(e->onVerifyNetwork);
    zfish_place(e->sharedHists);
    zfish_engine_init_body(e);
    // Native-graph cut flip fire 4: exercise the native EngineGraph owned-member
    // construction in-process (real allocator + real from_system) and assert its
    // host-independent invariants. Loud abort on divergence. Pure native, runs in
    // both builds; frees what it builds.
    if (!zfish_shadow_construct_engine_graph()) {
        std::fprintf(stderr, "zfish: native engine-graph construction shadow failed\n");
        std::abort();
    }
}
#endif  // ZFISH_LEGACY_CPP_TARGET

extern "C" {
// Memory-footprint probe for the C++ object graph, the layout reference the Zig
// reimplementation allocates against. Reported per object so the Zig side can
// pin and assert each size.
// M-FINAL cutover: legacy-oracle-only — this is sizeof/offsetof of the frozen src/ types, so the
// default build cannot define it once those types are forward-declared. The Zig cross-check
// (zfish_graph_verify_layouts) is comptime-gated to the legacy build, which verifies the pinned
// native constants against these real sizes every gate run; the default build trusts them.
#ifdef ZFISH_LEGACY_CPP_TARGET
std::size_t zfish_graph_layout_size(int which) {
    using namespace Stockfish;
    switch (which)
    {
    case 0:  return sizeof(Search::Worker);
    case 1:  return alignof(Search::Worker);
    case 2:  return sizeof(Thread);
    case 3:  return sizeof(ThreadPool);
    case 4:  return sizeof(Engine);
    case 5:  return sizeof(UCIEngine);
    case 6:  return sizeof(Search::SharedState);
    case 7:  return sizeof(Search::SearchManager);
    case 8:  return sizeof(Position);
    case 9:  return sizeof(StateInfo);
    case 10: return sizeof(TranspositionTable);
    case 11: return sizeof(Eval::NNUE::AccumulatorStack);
    case 12: return sizeof(Eval::NNUE::AccumulatorCaches);
    case 13: return sizeof(Search::RootMove);
    case 14: return alignof(Stockfish::Search::Worker);
    // Member offset probe (not a size): offsetof(Worker, tbConfig). Worker is not
    // standard-layout (it has reference members), so this is computed at runtime;
    // the native set_tb_config flip writes the Config fields through this offset.
    case 15: return offsetof(Search::Worker, tbConfig);
    case 16: return offsetof(Search::Worker, rootState);
    case 17: return offsetof(Search::Worker, lastIterationPV);
    default: return 0;
    }
}
#endif  // ZFISH_LEGACY_CPP_TARGET

void zfish_graph_verify_layouts();

// Stage-6 (Annex A) ownership beachhead: the UCIEngine footprint is now allocated
// and owned by Zig (main.zig: memory_port.stdAlignedAlloc/Free), and its lifetime
// is driven as four distinct Zig-orchestrated phases -- size/align probe, alloc,
// placement-construct, placement-destruct, free -- instead of one C++
// make_unique/delete. The C++ UCIEngine constructor still runs in full here (via
// placement new), so the constructed graph is byte-identical and parity is
// preserved; what moved to Zig is the storage, the lifetime, and the seam that
// later milestones (6b+) use to peel member construction out of the C++ ctor.
// M-FINAL: sizeof(UCIEngine) is now the native graph_layout.uci_engine_size constant
// (zig_src/main.zig); this C++ source-of-truth def is kept legacy-only. alignof stays C++.
#ifdef ZFISH_LEGACY_CPP_TARGET
std::size_t zfish_uci_engine_sizeof() { return sizeof(Stockfish::UCIEngine); }
#endif
std::size_t zfish_uci_engine_alignof() { return alignof(Stockfish::UCIEngine); }

#ifndef ZFISH_LEGACY_CPP_TARGET
// M-FINAL cutover: the native engine container (zig_src/native_engine.zig). The buffer
// holds a NativeEngine, not a C++ UCIEngine — these build/teardown its heap members.
extern "C" bool zfish_native_engine_construct_members(void* buf, const char* argv0);
extern "C" void zfish_native_engine_set_cli(void* buf, int argc, char* const* argv);
extern "C" void zfish_native_engine_destruct_members(void* buf);
extern "C" void zfish_native_threadpool_clear(void* pool);
#endif

void zfish_uci_engine_construct_at(void* storage, int argc, char* const* argv) {
    // Verify the Zig-side object-graph footprint still matches this C++ build before
    // anything is constructed, so any upstream layout drift fails loudly.
    zfish_graph_verify_layouts();

#ifndef ZFISH_LEGACY_CPP_TARGET
    // M-FINAL cutover: the buffer holds a NativeEngine (an ownership container of heap
    // members), NOT a C++ UCIEngine. Build the heap members + the inline live sub-objects
    // (updateContext / onVerifyNetwork), store argc/argv, then run the same post-member
    // work the UCIEngine ctor body did. UCIEngine::engine is at offset 0 (== storage) and
    // every member access routes through the accessors, so init_body / add_info_listener /
    // init_search_update_listeners / engine_options operate on the native storage unchanged.
    if (!zfish_native_engine_construct_members(storage, argv[0]))
        std::abort();
    zfish_native_engine_set_cli(storage, argc, argv);
    zfish_engine_init_body(storage);  // register options, set start position, size threads

    auto* uci = static_cast<Stockfish::UCIEngine*>(storage);
    // M-FINAL cutover: no add_info_listener — the default build's option callback messages are
    // emitted directly by apply_setoption (UCIEngine::print_info_string), so the C++ OptionsMap
    // info listener is unused and the OptionsMap is an empty stub.
    uci->init_search_update_listeners();  // sets the LIVE updateContext callbacks
    Stockfish::Tune::init(uci->engine_options());
    return;
#else
    // Legacy oracle: explicit per-member construction of a real C++ UCIEngine.
    auto* uci = static_cast<Stockfish::UCIEngine*>(storage);
    zfish_engine_construct_members(&uci->engine, argv[0]);
    ::new (&uci->cli) Stockfish::CommandLine(argc, const_cast<char**>(argv));
    uci->engine.get_options().add_info_listener([](const std::optional<std::string>& str) {
        if (str.has_value())
            Stockfish::UCIEngine::print_info_string(*str);
    });
    uci->init_search_update_listeners();
    Stockfish::Tune::init(uci->engine_options());
#endif
}

void zfish_uci_engine_destruct_at(void* storage) {
#ifndef ZFISH_LEGACY_CPP_TARGET
    // M-FINAL cutover: native teardown, no C++ ~UCIEngine. Free the states slot (if it was
    // never handed off to pool.setupStates), join+free the native Threads and null the
    // pool's threads vector, then free the heap members (delete threads runs ~ThreadPool,
    // which frees setupStates; delete network/options/numa; free binary_dir; destruct the
    // inline updateContext / onVerifyNetwork). states is freed by exactly one of
    // release_pending_state_slot / ~ThreadPool.
    zfish_engine_release_pending_state_slot(zfish_engine_states_slot_ptr(storage));
    zfish_native_threadpool_clear(zfish_engine_threads_ptr(storage));
    zfish_native_engine_destruct_members(storage);
#else
    auto* uci_engine = static_cast<Stockfish::UCIEngine*>(storage);
    zfish_engine_release_pending_state_slot(&uci_engine->engine.states);
    // Run ~UCIEngine in place; Zig frees the footprint afterwards.
    uci_engine->~UCIEngine();
#endif
}
}
