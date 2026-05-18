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

#include "nnue/network.h"

#include <cstdlib>
#include <fstream>
#include <functional>
#include <iostream>
#include <optional>
#include <type_traits>

#define INCBIN_SILENCE_BITCODE_WARNING
#include "incbin/incbin.h"

#include "evaluate.h"
#include "misc.h"
#include "position.h"
#include "types.h"
#include "nnue/nnue_architecture.h"
#include "nnue/nnue_common.h"
#include "nnue/nnue_misc.h"

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

namespace Stockfish::Eval::NNUE {

struct NetworkBridgeAccess {
    static const EvalFile& evalFile(const Network& network) { return network.evalFile; }

    static void loadUserNet(Network& network, const std::string& dir, const std::string& evalfilePath) {
        network.load_user_net(dir, evalfilePath);
    }

    static void loadInternal(Network& network) { network.load_internal(); }

    static bool saveNamed(const Network& network,
                          std::ostream&   stream,
                          const std::string& name,
                          const std::string& netDescription) {
        return network.save(stream, name, netDescription);
    }

    static const FeatureTransformer& featureTransformer(const Network& network) {
        return network.featureTransformer;
    }

    static const NetworkArchitecture& layer(const Network& network, std::size_t bucket) {
        return network.network[bucket];
    }
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

void zfish_network_load(void*                  network,
                        const unsigned char*   root_directory_ptr,
                        std::size_t            root_directory_len,
                        const unsigned char*   evalfile_path_ptr,
                        std::size_t            evalfile_path_len);
ZfishNetworkSaveResult zfish_network_save(const void*                network,
                                          std::uint8_t               has_filename,
                                          const unsigned char*       filename_ptr,
                                          std::size_t                filename_len);
ZfishNetworkVerifyResult zfish_network_verify(const void*              network,
                                              const unsigned char*     evalfile_path_ptr,
                                              std::size_t              evalfile_path_len);
ZfishNetworkEvalOutput zfish_network_evaluate(const void* network,
                                              const void* pos,
                                              void*       accumulator_stack,
                                              void*       cache);
ZfishNetworkTraceOutput zfish_network_trace_evaluate(const void* network,
                                                     const void* pos,
                                                     void*       accumulator_stack,
                                                     void*       cache);

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

void zfish_network_load_user_net(void*                network_ptr,
                                 const unsigned char* dir_ptr,
                                 std::size_t          dir_len,
                                 const unsigned char* path_ptr,
                                 std::size_t          path_len) {
    auto& network = *static_cast<Network*>(network_ptr);
    NetworkBridgeAccess::loadUserNet(network,
                                     std::string(reinterpret_cast<const char*>(dir_ptr), dir_len),
                                     std::string(reinterpret_cast<const char*>(path_ptr), path_len));
}

void zfish_network_load_internal(void* network_ptr) {
    auto& network = *static_cast<Network*>(network_ptr);
    NetworkBridgeAccess::loadInternal(network);
}

bool zfish_network_save_named(const void*          network_ptr,
                              const unsigned char* filename_ptr,
                              std::size_t          filename_len) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    const auto  actualFilename = std::string(reinterpret_cast<const char*>(filename_ptr), filename_len);
    std::ofstream stream(actualFilename, std::ios_base::binary);
    const auto& eval_file = NetworkBridgeAccess::evalFile(network);
    return NetworkBridgeAccess::saveNamed(network, stream, eval_file.current, eval_file.netDescription);
}

std::size_t zfish_network_piece_count(const void* pos_ptr) {
    return static_cast<const Position*>(pos_ptr)->count<ALL_PIECES>();
}

ZfishNetworkEvalOutput zfish_network_evaluate_bucket_raw(const void* network_ptr,
                                                         const void* pos_ptr,
                                                         void*       accumulator_stack_ptr,
                                                         void*       cache_ptr,
                                                         std::size_t bucket) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    const auto& pos = *static_cast<const Position*>(pos_ptr);
    auto&       accumulator_stack = *static_cast<AccumulatorStack*>(accumulator_stack_ptr);
    auto&       cache = *static_cast<AccumulatorCaches*>(cache_ptr);

    constexpr uint64_t alignment = CacheLineSize;
    alignas(alignment) TransformedFeatureType transformedFeatures[FeatureTransformer::BufferSize];

    ASSERT_ALIGNED(transformedFeatures, alignment);

    const auto psqt = NetworkBridgeAccess::featureTransformer(network).transform(pos,
                                                                                 accumulator_stack,
                                                                                 cache,
                                                                                 transformedFeatures,
                                                                                 bucket);
    const auto positional = NetworkBridgeAccess::layer(network, bucket).propagate(transformedFeatures);
    return {static_cast<int>(psqt), static_cast<int>(positional)};
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
    const auto result = zfish_network_save(this,
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

void Network::load_user_net(const std::string& dir, const std::string& evalfilePath) {
    std::ifstream stream(dir + evalfilePath, std::ios::binary);
    auto          description = load(stream);

    if (description.has_value())
    {
        evalFile.current        = evalfilePath;
        evalFile.netDescription = description.value();
    }
}

void Network::load_internal() {
    class MemoryBuffer: public std::basic_streambuf<char> {
       public:
        MemoryBuffer(char* p, size_t n) {
            setg(p, p, p + n);
            setp(p, p + n);
        }
    };

    MemoryBuffer buffer(const_cast<char*>(reinterpret_cast<const char*>(gEmbeddedNNUEData)),
                        size_t(gEmbeddedNNUESize));

    std::istream stream(&buffer);
    auto         description = load(stream);

    if (description.has_value())
    {
        evalFile.current        = evalFile.defaultName;
        evalFile.netDescription = description.value();
    }
}

void Network::initialize() { initialized = true; }

bool Network::save(std::ostream&      stream,
                   const std::string& name,
                   const std::string& netDescription) const {
    if (name.empty() || name == "None")
        return false;

    return write_parameters(stream, netDescription);
}

std::optional<std::string> Network::load(std::istream& stream) {
    initialize();
    std::string description;

    return read_parameters(stream, description) ? std::make_optional(description) : std::nullopt;
}

std::size_t Network::get_content_hash() const {
    if (!initialized)
        return 0;

    std::size_t h = 0;
    hash_combine(h, featureTransformer);
    for (auto&& layerstack : network)
        hash_combine(h, layerstack);
    hash_combine(h, evalFile);
    return h;
}

bool Network::read_header(std::istream& stream, std::uint32_t* hashValue, std::string* desc) const {
    std::uint32_t version, size;

    version    = read_little_endian<std::uint32_t>(stream);
    *hashValue = read_little_endian<std::uint32_t>(stream);
    size       = read_little_endian<std::uint32_t>(stream);
    if (!stream || version != Version)
        return false;
    desc->resize(size);
    stream.read(&(*desc)[0], size);
    return !stream.fail();
}

bool Network::write_header(std::ostream&      stream,
                           std::uint32_t      hashValue,
                           const std::string& desc) const {
    write_little_endian<std::uint32_t>(stream, Version);
    write_little_endian<std::uint32_t>(stream, hashValue);
    write_little_endian<std::uint32_t>(stream, std::uint32_t(desc.size()));
    stream.write(&desc[0], desc.size());
    return !stream.fail();
}

bool Network::read_parameters(std::istream& stream, std::string& netDescription) {
    std::uint32_t hashValue;
    if (!read_header(stream, &hashValue, &netDescription))
        return false;
    if (hashValue != Network::hash)
        return false;
    if (!Detail::read_parameters(stream, featureTransformer))
        return false;
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

}  // namespace Stockfish::Eval::NNUE
