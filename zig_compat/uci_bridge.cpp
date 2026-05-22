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

struct ZfishEngineNetworkVerifyResult {
    std::uint8_t should_exit;
    const char*  message;
};

struct ZfishEngineNetworkStatusItem {
    std::uint8_t status;
    const char*  error;
};

const char* zfish_engine_format_numa_info(const unsigned char* config_ptr, std::size_t config_len);
const char* zfish_engine_format_thread_binding(const ZfishCountPair* pairs_ptr, std::size_t pair_count);
const char* zfish_engine_format_thread_allocation(std::size_t          thread_count,
                                                  const unsigned char* binding_ptr,
                                                  std::size_t          binding_len);
const char* zfish_engine_thread_binding_information(const void* numa_context, const void* threads);
const char* zfish_engine_thread_allocation_information(const void* numa_context, const void* threads);
const char* zfish_engine_format_network_status(std::size_t          replica_index,
                                               std::uint8_t        status,
                                               const unsigned char* error_ptr,
                                               std::size_t          error_len);
const char* zfish_engine_evalfile_text(const void* engine_ptr);
const char* zfish_engine_syzygy_path_text(const void* engine_ptr);
void*       zfish_engine_position_ptr(void* engine_ptr);
const void* zfish_engine_network_ptr(const void* engine_ptr);
void*       zfish_engine_threads_ptr(void* engine_ptr);
void*       zfish_engine_tt_ptr(void* engine_ptr);
std::uint8_t zfish_engine_chess960_enabled(const void* engine_ptr);
ZfishEngineNetworkVerifyResult zfish_engine_network_verify_current(const void*          engine_ptr,
                                                                   const unsigned char* evalfile_ptr,
                                                                   std::size_t          evalfile_len);
std::size_t zfish_engine_network_status_count(const void* engine_ptr);
ZfishEngineNetworkStatusItem zfish_engine_network_status_at(const void* engine_ptr,
                                                            std::size_t index);
void zfish_engine_emit_verify_message(const void*          engine_ptr,
                                      const unsigned char* message_ptr,
                                      std::size_t          message_len);
void zfish_engine_verify_network_method(const void* engine_ptr);
void zfish_engine_search_clear_owner(void* engine_ptr);
const char* zfish_engine_trace_eval_owner(void* engine_ptr);
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
void zfish_engine_load_network(void*                threads,
                               void*                network,
                               const unsigned char* root_directory_ptr,
                               std::size_t          root_directory_len,
                               const unsigned char* evalfile_path_ptr,
                               std::size_t          evalfile_path_len);
void zfish_engine_save_network(void*                network,
                               std::uint8_t         has_filename,
                               const unsigned char* filename_ptr,
                               std::size_t          filename_len);
const char* zfish_engine_fen(const void* pos);
const char* zfish_engine_visualize(const void* pos);
void        zfish_tbprobe_add_tables(void* tables,
                                     const unsigned char* piece_types_ptr,
                                     std::size_t          piece_count);
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

int dtz_before_zeroing(WDLScore wdl) { return zfish_tbprobe_dtz_before_zeroing(int(wdl)); }

struct ZfishTBTablesEntry {
    Key           key;
    TBTable<WDL>* wdl;
    TBTable<DTZ>* dtz;

    template<TBType Type>
    TBTable<Type>* get() const {
        return (TBTable<Type>*) (Type == WDL ? (void*) wdl : (void*) dtz);
    }
};

struct ZfishTBTablesLayout {
    static constexpr std::uint32_t Size = 1 << 12;
    static constexpr std::uint32_t Overflow = 1;

    ZfishTBTablesEntry       hashTable[Size + Overflow];
    std::deque<TBTable<WDL>> wdlTable;
    std::deque<TBTable<DTZ>> dtzTable;
    std::size_t              foundDTZFiles;
    std::size_t              foundWDLFiles;
};

static_assert(sizeof(ZfishTBTablesLayout) == sizeof(TBTables));
static_assert(alignof(ZfishTBTablesLayout) == alignof(decltype(TBTables)));

void zfish_tbprobe_tables_insert(ZfishTBTablesLayout* tables,
                                 Key                  key,
                                 TBTable<WDL>*        wdl,
                                 TBTable<DTZ>*        dtz) {
    std::uint32_t      home_bucket = std::uint32_t(key) & (ZfishTBTablesLayout::Size - 1);
    ZfishTBTablesEntry entry{key, wdl, dtz};

    for (std::uint32_t bucket = home_bucket;
         bucket < ZfishTBTablesLayout::Size + ZfishTBTablesLayout::Overflow - 1;
         ++bucket)
    {
        Key other_key = tables->hashTable[bucket].key;
        if (other_key == key || !tables->hashTable[bucket].get<WDL>())
        {
            tables->hashTable[bucket] = entry;
            return;
        }

        const std::uint32_t other_home_bucket = std::uint32_t(other_key) & (ZfishTBTablesLayout::Size - 1);
        if (other_home_bucket > home_bucket)
        {
            std::swap(entry, tables->hashTable[bucket]);
            key         = other_key;
            home_bucket = other_home_bucket;
        }
    }

    std::cerr << "TB hash table size too low!" << std::endl;
    exit(EXIT_FAILURE);
}

}  // namespace

void TBTables::add(const std::vector<PieceType>& pieces) {
    zfish_tbprobe_add_tables(this, reinterpret_cast<const unsigned char*>(pieces.data()), pieces.size());
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
void zfish_position_fill_snapshot(const void* pos_ptr, ZfishPositionSnapshot* out);
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
void         zfish_thread_start_thinking(void*        pool,
                                         const void*  options,
                                         void*        pos,
                                         const void*  limits,
                                         void*        states_slot);
void zfish_threadpool_reconfigure(void*       pool,
                                  const void* numa_config,
                                  const void* shared_state,
                                  const void* update_context);
void zfish_thread_run_callback(void* thread_ptr, ZfishOpaqueCallback callback, void* context);
void zfish_threadpool_clear(void* pool);
void zfish_threadpool_start_searching(void* pool);
void zfish_threadpool_wait_for_search_finished(void* pool);
void zfish_threadpool_ensure_network_replicated(void* pool);
std::uint64_t zfish_threadpool_nodes_searched(void* pool);
std::uint64_t zfish_threadpool_tb_hits(void* pool);
std::size_t   zfish_threadpool_best_thread_index(void* pool);
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
void zfish_threadpool_add_main_thread_bound(void*       pool,
                                            const void* numa_config,
                                            const void* shared_state,
                                            const void* update_context,
                                            std::size_t thread_id,
                                            std::size_t idx_in_numa,
                                            std::size_t total_numa,
                                            std::size_t numa_id);
void zfish_threadpool_add_main_thread_unbound(void*       pool,
                                              const void* shared_state,
                                              const void* update_context,
                                              std::size_t thread_id,
                                              std::size_t idx_in_numa,
                                              std::size_t total_numa,
                                              std::size_t numa_id);
void zfish_threadpool_add_worker_thread_bound(void*       pool,
                                              const void* numa_config,
                                              const void* shared_state,
                                              std::size_t thread_id,
                                              std::size_t idx_in_numa,
                                              std::size_t total_numa,
                                              std::size_t numa_id);
void zfish_threadpool_add_worker_thread_unbound(void*       pool,
                                                const void* shared_state,
                                                std::size_t thread_id,
                                                std::size_t idx_in_numa,
                                                std::size_t total_numa,
                                                std::size_t numa_id);
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

        const std::size_t count = zfish_movepick_score_list(
            kind, &context, reinterpret_cast<ZfishMoveSortEntry*>(cur));

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

static_assert(sizeof(Move) == sizeof(std::uint16_t));

extern "C" void zfish_position_fill_snapshot(const void* pos_ptr, ZfishPositionSnapshot* out) {
    const auto& pos = *static_cast<const Position*>(pos_ptr);

    out->side_to_move = static_cast<std::uint8_t>(pos.side_to_move());
    out->pieces_all = pos.pieces();
    out->pieces_by_color[WHITE] = pos.pieces(WHITE);
    out->pieces_by_color[BLACK] = pos.pieces(BLACK);
    out->pieces_by_type[NO_PIECE_TYPE] = out->pieces_all;
    out->pieces_by_type[PAWN] = pos.pieces(PAWN);
    out->pieces_by_type[KNIGHT] = pos.pieces(KNIGHT);
    out->pieces_by_type[BISHOP] = pos.pieces(BISHOP);
    out->pieces_by_type[ROOK] = pos.pieces(ROOK);
    out->pieces_by_type[QUEEN] = pos.pieces(QUEEN);
    out->pieces_by_type[KING] = pos.pieces(KING);
    out->blockers_for_king[WHITE] = pos.blockers_for_king(WHITE);
    out->blockers_for_king[BLACK] = pos.blockers_for_king(BLACK);
    out->pinners[WHITE] = pos.pinners(WHITE);
    out->pinners[BLACK] = pos.pinners(BLACK);
    out->king_square[WHITE] = static_cast<std::uint8_t>(pos.square<KING>(WHITE));
    out->king_square[BLACK] = static_cast<std::uint8_t>(pos.square<KING>(BLACK));
    out->ep_square = static_cast<std::uint8_t>(pos.ep_square());
    out->checkers = pos.checkers();

    std::uint8_t rights = 0;
    for (const auto cr : {WHITE_OO, WHITE_OOO, BLACK_OO, BLACK_OOO})
    {
        const auto index = static_cast<std::size_t>(cr);
        if (pos.can_castle(cr))
            rights |= static_cast<std::uint8_t>(cr);
        out->castling_impeded[index] = static_cast<std::uint8_t>(pos.castling_impeded(cr) ? 1 : 0);
        out->castling_rook_square[index] =
          static_cast<std::uint8_t>(pos.castling_rook_square(cr));
    }

    out->castling_rights = rights;
    out->pawn_key = pos.pawn_key();
    out->key = pos.key();
    out->material_value = 534 * pos.count<PAWN>() + pos.non_pawn_material();
    out->rule50_count = pos.rule50_count();
    out->game_ply = pos.game_ply();
    out->is_chess960 = static_cast<std::uint8_t>(pos.is_chess960() ? 1 : 0);

    for (std::size_t square = 0; square < 64; ++square)
        out->board[square] = static_cast<std::uint8_t>(pos.piece_on(static_cast<Square>(square)));
}

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

std::uint8_t TTEntry::relative_age(std::uint8_t curr_generation) const {
    return zfish_tt_entry_relative_age(reinterpret_cast<const ZfishTtEntry*>(this), curr_generation);
}

TTWriter::TTWriter(TTEntry* tte) :
    entry(tte) {}

void TTWriter::write(
  Key k, Value v, bool pv, Bound b, Depth d, Move m, Value ev, std::uint8_t curr_generation) {
        zfish_tt_entry_save(reinterpret_cast<ZfishTtEntry*>(entry), k, v,
                                                static_cast<std::uint8_t>(pv ? 1 : 0), static_cast<std::uint8_t>(b), d,
                                                DEPTH_NONE, m.raw(), ev, curr_generation);
}

struct Cluster {
    TTEntry entry[ClusterSize];
    char    padding[2];
};

static_assert(sizeof(Cluster) == 32, "Suboptimal Cluster size");

extern "C" void* zfish_tt_alloc_clusters(std::size_t byte_count) {
    return aligned_large_pages_alloc(byte_count);
}

extern "C" void zfish_tt_free_clusters(void* ptr) { aligned_large_pages_free(ptr); }

extern "C" void zfish_tt_report_alloc_failure(std::size_t mb_size) {
    std::cerr << "Failed to allocate " << mb_size << "MB for transposition table." << std::endl;
    std::exit(EXIT_FAILURE);
}

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

void TranspositionTable::resize(size_t mbSize, ThreadPool& threads) {
    zfish_tt_resize_state(reinterpret_cast<void**>(&table), &clusterCount, &generation8, mbSize,
                          &threads);
}

void TranspositionTable::clear(ThreadPool& threads) {
    zfish_tt_clear_state(table, clusterCount, &generation8, &threads);
}

int TranspositionTable::hashfull(int maxAge) const {
    return zfish_tt_hashfull(reinterpret_cast<const ZfishTtCluster*>(table), clusterCount,
                             generation8, maxAge);
}

void TranspositionTable::new_search() { generation8 = zfish_tt_generation_next(generation8); }

std::uint8_t TranspositionTable::generation() const { return generation8; }

std::tuple<bool, TTData, TTWriter> TranspositionTable::probe(const Key key) const {
    const auto output = zfish_tt_probe_table(table, clusterCount, key, generation8, DEPTH_NONE);
    auto* writer_entry = static_cast<TTEntry*>(output.writer_ptr);
    assert(writer_entry != nullptr);

    if (output.found != 0)
    {
        const auto& data = output.data;
        return {true,
                TTData{Move(data.move16), Value(data.value16), Value(data.eval16), Depth(data.depth),
                       Bound(data.bound), data.is_pv != 0},
                TTWriter(writer_entry)};
    }

    return {false, TTData{Move::none(), VALUE_NONE, VALUE_NONE, DEPTH_NONE, BOUND_NONE, false},
            TTWriter(writer_entry)};
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

uint64_t ThreadPool::nodes_searched() const {
    return zfish_threadpool_nodes_searched(const_cast<ThreadPool*>(this));
}
uint64_t ThreadPool::tb_hits() const { return zfish_threadpool_tb_hits(const_cast<ThreadPool*>(this)); }

static size_t next_power_of_two(uint64_t count) {
    return zfish_thread_next_power_of_two(count);
}

void ThreadPool::set(const NumaConfig&                           numaConfig,
                     Search::SharedState                         sharedState,
                     const Search::SearchManager::UpdateContext& updateContext) {
    zfish_threadpool_reconfigure(this, &numaConfig, &sharedState, &updateContext);
}

void ThreadPool::clear() {
    zfish_threadpool_clear(this);
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
        auto&       tt = *static_cast<TranspositionTable*>(tt_ptr);
        auto&       shared_hists = *static_cast<std::map<NumaIndex, SharedHistories>*>(shared_hists_ptr);
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

void zfish_engine_network_load_replicated(void*                network_ptr,
                                          const unsigned char* root_directory_ptr,
                                          std::size_t          root_directory_len,
                                          const unsigned char* evalfile_path_ptr,
                                          std::size_t          evalfile_path_len) {
    auto& network = *static_cast<LazyNumaReplicatedSystemWide<Eval::NNUE::Network>*>(network_ptr);
    const std::string root_directory(reinterpret_cast<const char*>(root_directory_ptr),
                                     root_directory_len);
    const std::string evalfile_path(reinterpret_cast<const char*>(evalfile_path_ptr),
                                    evalfile_path_len);

    network.modify_and_replicate([&](Eval::NNUE::Network& network_) {
        network_.load(root_directory, evalfile_path);
    });
}

void zfish_engine_network_save_replicated(void*                network_ptr,
                                          std::uint8_t         has_filename,
                                          const unsigned char* filename_ptr,
                                          std::size_t          filename_len) {
    auto& network = *static_cast<LazyNumaReplicatedSystemWide<Eval::NNUE::Network>*>(network_ptr);
    const std::optional<std::string> filename =
      has_filename != 0
        ? std::optional<std::string>(
            std::string(reinterpret_cast<const char*>(filename_ptr), filename_len))
        : std::nullopt;

    network.modify_and_replicate(
      [&](Eval::NNUE::Network& network_) { network_.save(filename); });
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
    TBFile            file(code + ".rtbw");
    const bool        is_open = file.is_open();
    if (is_open)
        file.close();
    return static_cast<std::uint8_t>(is_open ? 1 : 0);
}

std::uint8_t zfish_tbprobe_has_dtz_file(const unsigned char* code_ptr, std::size_t code_len) {
    const std::string code(reinterpret_cast<const char*>(code_ptr), code_len);
    TBFile            file(code + ".rtbz");
    const bool        is_open = file.is_open();
    if (is_open)
        file.close();
    return static_cast<std::uint8_t>(is_open ? 1 : 0);
}

void zfish_tbprobe_note_dtz_found(void* tables_ptr) {
    auto* tables = reinterpret_cast<ZfishTBTablesLayout*>(tables_ptr);
    tables->foundDTZFiles++;
}

void zfish_tbprobe_register_wdl_table(void*                tables_ptr,
                                      const unsigned char* code_ptr,
                                      std::size_t          code_len,
                                      std::size_t          piece_count) {
    auto*             tables = reinterpret_cast<ZfishTBTablesLayout*>(tables_ptr);
    const std::string code(reinterpret_cast<const char*>(code_ptr), code_len);

    tables->foundWDLFiles++;
    MaxCardinality = std::max(int(piece_count), MaxCardinality);

    tables->wdlTable.emplace_back(code);
    tables->dtzTable.emplace_back(tables->wdlTable.back());

    zfish_tbprobe_tables_insert(
      tables, tables->wdlTable.back().key, &tables->wdlTable.back(), &tables->dtzTable.back());
    zfish_tbprobe_tables_insert(
      tables, tables->wdlTable.back().key2, &tables->wdlTable.back(), &tables->dtzTable.back());
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
    zfish_thread_start_thinking(this, &options, &pos, &limits, &states);
}

Thread* ThreadPool::get_best_thread() const {
    return threads[zfish_threadpool_best_thread_index(const_cast<ThreadPool*>(this))].get();
}

void ThreadPool::start_searching() {
    zfish_threadpool_start_searching(this);
}

void ThreadPool::wait_for_search_finished() const {
    zfish_threadpool_wait_for_search_finished(const_cast<ThreadPool*>(this));
}

void ThreadPool::ensure_network_replicated() {
    zfish_threadpool_ensure_network_replicated(this);
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

std::uint8_t zfish_misc_has_large_pages_flag() {
    return has_large_pages() ? 1 : 0;
}

int zfish_misc_hardware_concurrency_value() {
    return int(get_hardware_concurrency());
}
}

std::string compiler_info() {
    const char* rendered = zfish_misc_compiler_info_text();
    if (!rendered)
        std::abort();

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

std::string Engine::get_numa_config_as_string() const {
    return numaContext.get_numa_config().to_string();
}

std::string Engine::numa_config_information_as_string() const {
    auto cfgStr = get_numa_config_as_string();
    const char* rendered = zfish_engine_format_numa_info(
      reinterpret_cast<const unsigned char*>(cfgStr.data()), cfgStr.size());
    if (!rendered)
        std::abort();
    std::string result(rendered);
    std::free(const_cast<char*>(rendered));
    return result;
}

std::string Engine::thread_binding_information_as_string() const {
    const char* rendered = zfish_engine_thread_binding_information(&numaContext, &threads);
    if (!rendered)
        std::abort();
    std::string result(rendered);
    std::free(const_cast<char*>(rendered));
    return result;
}

std::string Engine::thread_allocation_information_as_string() const {
    const char* rendered = zfish_engine_thread_allocation_information(&numaContext, &threads);
    if (!rendered)
        std::abort();
    std::string result(rendered);
    std::free(const_cast<char*>(rendered));
    return result;
}

void Engine::verify_network() const {
    zfish_engine_verify_network_method(this);
}

std::unique_ptr<Eval::NNUE::Network> Engine::get_default_network() const {

    auto network_ = std::make_unique<NN::Network>(NN::EvalFile{EvalFileDefaultName, "None", ""});

    network_->load(binaryDirectory, "");

    return network_;
}

void Engine::load_network(const std::string& file) {
    zfish_engine_load_network(&threads, &network,
                              reinterpret_cast<const unsigned char*>(binaryDirectory.data()),
                              binaryDirectory.size(),
                              reinterpret_cast<const unsigned char*>(file.data()), file.size());
}

void Engine::save_network(const std::pair<std::optional<std::string>, std::string> file) {
    const std::string filename = file.first.value_or(std::string{});
    zfish_engine_save_network(&network, static_cast<std::uint8_t>(file.first.has_value()),
                              reinterpret_cast<const unsigned char*>(filename.data()),
                              filename.size());
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

std::string take_string_and_free_engine_required_uci(const char* rendered) {
    if (!rendered)
        std::abort();

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

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
    states.reset();

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
    zfish_engine_search_clear_owner(this);
}

void Engine::trace_eval() const {
    const char* rendered = zfish_engine_trace_eval_owner(const_cast<Engine*>(this));
    if (!rendered)
        std::abort();

    sync_cout << "\n" << rendered << sync_endl;
    std::free(const_cast<char*>(rendered));
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

int zfish_engine_max_threads_value() { return MaxThreads; }

int zfish_engine_max_hash_mb_value() { return MaxHashMB; }

void zfish_engine_skill_elo_bounds(int* low_ptr, int* high_ptr) {
    if (low_ptr)
        *low_ptr = Stockfish::Search::Skill::LowestElo;
    if (high_ptr)
        *high_ptr = Stockfish::Search::Skill::HighestElo;
}

void zfish_engine_set_start_position(void* engine_ptr) {
    auto* engine = static_cast<Engine*>(engine_ptr);
    const auto error = engine->set_position(StartFEN, {});
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

void zfish_engine_resize_threads_method(void* engine_ptr) {
    static_cast<Engine*>(engine_ptr)->resize_threads();
}

void zfish_engine_set_tt_size_method(void* engine_ptr, std::size_t mb) {
    static_cast<Engine*>(engine_ptr)->set_tt_size(mb);
}

void zfish_engine_search_clear_method(void* engine_ptr) {
    static_cast<Engine*>(engine_ptr)->search_clear();
}

void zfish_engine_load_network_method(void*                engine_ptr,
                                      const unsigned char* file_ptr,
                                      std::size_t          file_len) {
    static_cast<Engine*>(engine_ptr)->load_network(
      std::string(reinterpret_cast<const char*>(file_ptr), file_len));
}

void zfish_engine_set_numa_config_from_option_method(void*                engine_ptr,
                                                     const unsigned char* value_ptr,
                                                     std::size_t          value_len) {
    static_cast<Engine*>(engine_ptr)->set_numa_config_from_option(
      std::string(reinterpret_cast<const char*>(value_ptr), value_len));
}

const char* zfish_engine_numa_config_info_text(const void* engine_ptr) {
    return alloc_c_string(static_cast<const Engine*>(engine_ptr)->numa_config_information_as_string());
}

const char* zfish_engine_thread_allocation_info_text(const void* engine_ptr) {
    return alloc_c_string(
      static_cast<const Engine*>(engine_ptr)->thread_allocation_information_as_string());
}

const char* zfish_engine_evalfile_text(const void* engine_ptr) {
    return alloc_c_string(std::string(static_cast<const Engine*>(engine_ptr)->get_options()["EvalFile"]));
}

const char* zfish_engine_syzygy_path_text(const void* engine_ptr) {
    return alloc_c_string(std::string(static_cast<const Engine*>(engine_ptr)->get_options()["SyzygyPath"]));
}

void* zfish_engine_position_ptr(void* engine_ptr) {
    return &static_cast<Engine*>(engine_ptr)->pos;
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

std::uint8_t zfish_engine_chess960_enabled(const void* engine_ptr) {
    return static_cast<std::uint8_t>(static_cast<int>(static_cast<const Engine*>(engine_ptr)->get_options()["UCI_Chess960"]));
}

ZfishEngineNetworkVerifyResult zfish_engine_network_verify_current(const void*          engine_ptr,
                                                                   const unsigned char* evalfile_ptr,
                                                                   std::size_t          evalfile_len) {
    const auto* engine = static_cast<const Engine*>(engine_ptr);
    const auto result = zfish_network_verify(engine->network.operator->(), evalfile_ptr, evalfile_len);
    return {result.should_exit, result.message};
}

std::size_t zfish_engine_network_status_count(const void* engine_ptr) {
    const auto* engine = static_cast<const Engine*>(engine_ptr);
    return engine->network.get_status_and_errors().size();
}

ZfishEngineNetworkStatusItem zfish_engine_network_status_at(const void* engine_ptr,
                                                            std::size_t index) {
    const auto* engine = static_cast<const Engine*>(engine_ptr);
    const auto  statuses = engine->network.get_status_and_errors();
    assert(index < statuses.size());

    const auto& [status, error] = statuses[index];
    const std::string error_text = error.value_or(std::string{});
    return {
      static_cast<std::uint8_t>(status),
      error_text.empty() ? nullptr : alloc_c_string(error_text),
    };
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
void          zfish_position_init_runtime();
const char*   zfish_bitboard_pretty(Stockfish::Bitboard bitboard);
void          zfish_bitboards_init();
ZfishUciDispatchResult zfish_uci_dispatch_command(void* engine, const unsigned char* input_ptr,
                                                  std::size_t input_len);
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

std::string Engine::fen() const {
    return take_string_and_free_required(zfish_engine_fen(&pos));
}

void Engine::flip() { pos.flip(); }

std::string Engine::visualize() const {
    return take_string_and_free_required(zfish_engine_visualize(&pos));
}

int Engine::get_hashfull(int maxAge) const { return tt.hashfull(maxAge); }

std::string Eval::trace(Position& pos, const Eval::NNUE::Network& network) {
    return take_string_and_free_required(zfish_engine_eval_trace(&pos, &network));
}

extern "C" {

std::uint64_t zfish_position_material_zobrist(std::uint8_t piece, std::size_t count_index) {
    return Stockfish::Zobrist::psq[piece][8 + count_index];
}

void zfish_position_init_runtime() {
    Stockfish::Position::init();
}

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

std::optional<PositionSetError> Position::set(const string& code, Color c, StateInfo* si) {
    const auto fenStr = take_string_and_free_required(zfish_position_build_endgame_fen(
      reinterpret_cast<const unsigned char*>(code.data()), code.size(), static_cast<std::uint8_t>(c)));
    return set(fenStr, false, si);
}

string Position::fen() const {
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

namespace {

std::atomic<std::uint64_t> zfish_last_nodes_searched = 0;

}  // namespace

extern "C" {
void zfish_uci_loop_runtime(void* engine_ptr);
void zfish_uci_bench_runtime(void* engine_ptr, const unsigned char* args_ptr, std::size_t args_len);
void zfish_uci_benchmark_runtime(void* engine_ptr,
                                                                 const unsigned char* args_ptr,
                                                                 std::size_t          args_len);
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
        zfish_last_nodes_searched.store(i.nodes, std::memory_order_relaxed);
        on_update_full(i, engine.get_options()["UCI_ShowWDL"]);
    });
    engine.set_on_bestmove([](const auto& bm, const auto& p) { on_bestmove(bm, p); });
    engine.set_on_verify_network([](const auto& s) { print_info_string(s); });
}

void UCIEngine::loop() { zfish_uci_loop_runtime(this); }

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

const char* zfish_uci_read_command_line() {
    std::string command;
    if (!std::getline(std::cin, command))
        return nullptr;

    return alloc_c_string(command);
}

std::uint64_t zfish_uci_engine_perft_depth(void* uci_ptr, int depth) {
        auto* uci_engine = static_cast<UCIEngine*>(uci_ptr);
        const auto nodes = uci_engine->engine.perft(
            uci_engine->engine.fen(), depth, uci_engine->engine.get_options()["UCI_Chess960"]);
        sync_cout << "\nNodes searched: " << nodes << "\n" << sync_endl;
        return nodes;
}

void zfish_uci_engine_wait_finished(void* uci_ptr) {
    static_cast<UCIEngine*>(uci_ptr)->engine.wait_for_search_finished();
}

std::uint64_t zfish_uci_engine_nodes_searched(const void*) {
    return zfish_last_nodes_searched.load(std::memory_order_relaxed);
}

void zfish_uci_engine_reset_nodes_searched() {
    zfish_last_nodes_searched.store(0, std::memory_order_relaxed);
}

int zfish_uci_engine_hashfull(const void* uci_ptr, int max_age) {
    return static_cast<const UCIEngine*>(uci_ptr)->engine.get_hashfull(max_age);
}

const char* zfish_uci_engine_fen_text(const void* uci_ptr) {
    return alloc_c_string(static_cast<const UCIEngine*>(uci_ptr)->engine.fen());
}

const char* zfish_uci_engine_numa_config_string(const void* uci_ptr) {
    return alloc_c_string(static_cast<const UCIEngine*>(uci_ptr)->engine.get_numa_config_as_string());
}

const char* zfish_uci_engine_thread_binding_info_text(const void* uci_ptr) {
    return alloc_c_string(
      static_cast<const UCIEngine*>(uci_ptr)->engine.thread_binding_information_as_string());
}

void zfish_uci_set_quiet_listeners(void* uci_ptr) {
    auto* uci_engine = static_cast<UCIEngine*>(uci_ptr);
    uci_engine->engine.set_on_update_full([](const Engine::InfoFull& i) {
        zfish_last_nodes_searched.store(i.nodes, std::memory_order_relaxed);
    });
    uci_engine->engine.set_on_iter([](const auto&) {});
    uci_engine->engine.set_on_update_no_moves([](const auto&) {});
    uci_engine->engine.set_on_bestmove([](const auto&, const auto&) {});
    uci_engine->engine.set_on_verify_network([](const auto&) {});
}

void zfish_uci_set_default_listeners(void* uci_ptr) {
    static_cast<UCIEngine*>(uci_ptr)->init_search_update_listeners();
}

void zfish_uci_engine_stop_search(void* uci_ptr) {
    static_cast<UCIEngine*>(uci_ptr)->engine.stop();
}

void zfish_uci_engine_set_ponderhit(void* uci_ptr, std::uint8_t ponderhit) {
    static_cast<UCIEngine*>(uci_ptr)->engine.set_ponderhit(ponderhit != 0);
}

void zfish_uci_engine_print_uci(void* uci_ptr) {
    auto* uci_engine = static_cast<UCIEngine*>(uci_ptr);
    sync_cout << "id name " << engine_info(true) << "\n" << uci_engine->engine.get_options()
              << sync_endl;
    sync_cout << "uciok" << sync_endl;
}

void zfish_uci_engine_apply_setoption(void*                uci_ptr,
                                      const unsigned char* name_ptr,
                                      std::size_t          name_len,
                                      const unsigned char* value_ptr,
                                      std::size_t          value_len,
                                      std::uint8_t         has_value) {
    auto* uci_engine = static_cast<UCIEngine*>(uci_ptr);
    uci_engine->engine.wait_for_search_finished();

    std::ostringstream command;
    command << "name " << std::string(reinterpret_cast<const char*>(name_ptr), name_len);
    if (has_value != 0)
        command << " value " << std::string(reinterpret_cast<const char*>(value_ptr), value_len);

    std::istringstream is(command.str());
    uci_engine->engine.get_options().setoption(is);
}

const char* zfish_uci_engine_apply_position(void*                uci_ptr,
                                            const unsigned char* fen_ptr,
                                            std::size_t          fen_len,
                                            const unsigned char* moves_ptr,
                                            std::size_t          moves_len) {
    auto* uci_engine = static_cast<UCIEngine*>(uci_ptr);

    const auto fen = std::string(reinterpret_cast<const char*>(fen_ptr), fen_len);
    const auto moves_text = std::string(reinterpret_cast<const char*>(moves_ptr), moves_len);

    std::vector<std::string> moves;
    if (!moves_text.empty())
    {
        std::istringstream moves_stream(moves_text);
        std::string        move;
        while (std::getline(moves_stream, move, '\n'))
        {
            if (!move.empty())
                moves.push_back(move);
        }
    }

    const auto error = uci_engine->engine.set_position(fen, moves);
    if (!error)
        return nullptr;

    return alloc_c_string(error->what());
}

void zfish_uci_engine_go_parsed(void* uci_ptr, ZfishParsedLimits parsed) {
    auto* uci_engine = static_cast<UCIEngine*>(uci_ptr);

    UCIEngine::print_info_string(uci_engine->engine.numa_config_information_as_string());
    UCIEngine::print_info_string(uci_engine->engine.thread_allocation_information_as_string());

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

    if (limits.perft)
        zfish_uci_engine_perft_depth(uci_engine, limits.perft);
    else
        uci_engine->engine.go(limits);
}

void zfish_uci_engine_search_clear(void* uci_ptr) {
    static_cast<UCIEngine*>(uci_ptr)->engine.search_clear();
}

void zfish_uci_engine_flip(void* uci_ptr) {
    static_cast<UCIEngine*>(uci_ptr)->engine.flip();
}

const char* zfish_uci_engine_visualize_text(const void* uci_ptr) {
    return alloc_c_string(static_cast<const UCIEngine*>(uci_ptr)->engine.visualize());
}

void zfish_uci_engine_trace_eval(void* uci_ptr) {
    static_cast<UCIEngine*>(uci_ptr)->engine.trace_eval();
}

void zfish_uci_engine_export_net(void*                uci_ptr,
                                 const unsigned char* filename_ptr,
                                 std::size_t          filename_len,
                                 std::uint8_t         has_filename) {
    auto* uci_engine = static_cast<UCIEngine*>(uci_ptr);
    std::pair<std::optional<std::string>, std::string> file;
    if (has_filename != 0)
    {
        file.second = std::string(reinterpret_cast<const char*>(filename_ptr), filename_len);
        file.first = file.second;
    }
    uci_engine->engine.save_network(file);
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

void zfish_uci_loop_engine(void* engine_ptr) {
    static_cast<Stockfish::UCIEngine*>(engine_ptr)->loop();
}

void zfish_uci_destroy_engine(void* engine_ptr) {
    auto* uci_engine = static_cast<Stockfish::UCIEngine*>(engine_ptr);
    zfish_engine_release_pending_state_slot(&uci_engine->engine.states);
    delete uci_engine;
}
}
