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

#include <array>
#include <cassert>
#include <cstdint>
#include <type_traits>

#include "nnue/nnue_accumulator.h"
#include "nnue/features/full_threats.h"
#include "nnue/features/half_ka_v2_hm.h"

#include <new>

#include "bitboard.h"
#include "nnue/nnue_feature_transformer.h"  // IWYU pragma: keep
#include "nnue/simd.h"

namespace Stockfish::Eval::NNUE {

using namespace SIMD;

namespace {

void update_accumulator_refresh_cache(Color                            perspective,
                                      const FeatureTransformer&        featureTransformer,
                                      const Position&                  pos,
                                      AccumulatorState<PSQFeatureSet>& accumulatorState,
                                      AccumulatorCaches&               cache);

void update_threats_accumulator_full(Color                               perspective,
                                     const FeatureTransformer&           featureTransformer,
                                     const Position&                     pos,
                                     AccumulatorState<ThreatFeatureSet>& accumulatorState);

constexpr std::uint8_t ZfishAccumulatorPsqFeature    = 0;
constexpr std::uint8_t ZfishAccumulatorThreatFeature = 1;

extern "C" {
struct ZfishAccumulatorStackPushResult {
    void* dirty_piece;
    void* dirty_threats;
};

const void* zfish_accumulator_stack_latest_psq(const void* stack);
const void* zfish_accumulator_stack_latest_threat(const void* stack);
void*       zfish_accumulator_stack_mut_latest_psq(void* stack);
void*       zfish_accumulator_stack_mut_latest_threat(void* stack);
const void* zfish_accumulator_stack_psq_array(const void* stack);
const void* zfish_accumulator_stack_threat_array(const void* stack);
void*       zfish_accumulator_stack_mut_psq_array(void* stack);
void*       zfish_accumulator_stack_mut_threat_array(void* stack);
void        zfish_accumulator_stack_reset(void* stack);
ZfishAccumulatorStackPushResult zfish_accumulator_stack_push(void* stack);
void                            zfish_accumulator_stack_pop(void* stack);
}

}  // namespace

template<typename T>
const AccumulatorState<T>& AccumulatorStack::latest() const noexcept {
    static_assert(std::is_same_v<T, PSQFeatureSet> || std::is_same_v<T, ThreatFeatureSet>,
                  "Invalid Feature Set Type");

    if constexpr (std::is_same_v<T, PSQFeatureSet>)
        return *static_cast<const AccumulatorState<PSQFeatureSet>*>(
          zfish_accumulator_stack_latest_psq(this));

    if constexpr (std::is_same_v<T, ThreatFeatureSet>)
        return *static_cast<const AccumulatorState<ThreatFeatureSet>*>(
          zfish_accumulator_stack_latest_threat(this));
}

template const AccumulatorState<PSQFeatureSet>& AccumulatorStack::latest() const noexcept;
template const AccumulatorState<ThreatFeatureSet>& AccumulatorStack::latest() const noexcept;

template<typename T>
AccumulatorState<T>& AccumulatorStack::mut_latest() noexcept {
    static_assert(std::is_same_v<T, PSQFeatureSet> || std::is_same_v<T, ThreatFeatureSet>,
                  "Invalid Feature Set Type");

    if constexpr (std::is_same_v<T, PSQFeatureSet>)
        return *static_cast<AccumulatorState<PSQFeatureSet>*>(
          zfish_accumulator_stack_mut_latest_psq(this));

    if constexpr (std::is_same_v<T, ThreatFeatureSet>)
        return *static_cast<AccumulatorState<ThreatFeatureSet>*>(
          zfish_accumulator_stack_mut_latest_threat(this));
}

template<typename T>
const std::array<AccumulatorState<T>, AccumulatorStack::MaxSize>&
AccumulatorStack::accumulators() const noexcept {
    static_assert(std::is_same_v<T, PSQFeatureSet> || std::is_same_v<T, ThreatFeatureSet>,
                  "Invalid Feature Set Type");

    if constexpr (std::is_same_v<T, PSQFeatureSet>)
        return *static_cast<const std::array<AccumulatorState<PSQFeatureSet>, MaxSize>*>(
          zfish_accumulator_stack_psq_array(this));

    if constexpr (std::is_same_v<T, ThreatFeatureSet>)
        return *static_cast<const std::array<AccumulatorState<ThreatFeatureSet>, MaxSize>*>(
          zfish_accumulator_stack_threat_array(this));
}

template<typename T>
std::array<AccumulatorState<T>, AccumulatorStack::MaxSize>&
AccumulatorStack::mut_accumulators() noexcept {
    static_assert(std::is_same_v<T, PSQFeatureSet> || std::is_same_v<T, ThreatFeatureSet>,
                  "Invalid Feature Set Type");

    if constexpr (std::is_same_v<T, PSQFeatureSet>)
        return *static_cast<std::array<AccumulatorState<PSQFeatureSet>, MaxSize>*>(
          zfish_accumulator_stack_mut_psq_array(this));

    if constexpr (std::is_same_v<T, ThreatFeatureSet>)
        return *static_cast<std::array<AccumulatorState<ThreatFeatureSet>, MaxSize>*>(
          zfish_accumulator_stack_mut_threat_array(this));
}

void AccumulatorStack::reset() noexcept {
    zfish_accumulator_stack_reset(this);
}

std::pair<DirtyPiece&, DirtyThreats&> AccumulatorStack::push() noexcept {
    const auto pushed = zfish_accumulator_stack_push(this);
    return {*static_cast<DirtyPiece*>(pushed.dirty_piece),
            *static_cast<DirtyThreats*>(pushed.dirty_threats)};
}

void AccumulatorStack::pop() noexcept {
    zfish_accumulator_stack_pop(this);
}

extern "C" {
struct ZfishDirtyThreatRaw {
    std::uint32_t data;
};

void zfish_accumulator_evaluate(void*                  stack,
                                const void*            pos,
                                const void*            feature_transformer,
                                void*                  cache);

std::uint8_t zfish_accumulator_king_square(const void* pos_ptr, std::uint8_t perspective) {
    const auto& pos = *static_cast<const Position*>(pos_ptr);
    return static_cast<std::uint8_t>(pos.square<KING>(Color(perspective)));
}

void zfish_accumulator_position_snapshot(const void* pos_ptr, std::uint8_t* pieces_out) {
    const auto& pos = *static_cast<const Position*>(pos_ptr);
    const auto& pieces = pos.piece_array();

    for (Square sq = SQUARE_ZERO; sq < SQUARE_NB; ++sq)
        pieces_out[sq] = static_cast<std::uint8_t>(pieces[sq]);
}

void* zfish_accumulator_cache_entry(void* cache_ptr, std::uint8_t king_square, std::uint8_t perspective) {
    auto& cache = *static_cast<AccumulatorCaches*>(cache_ptr);
    return &cache[Square(king_square)][Color(perspective)];
}

const std::int16_t* zfish_accumulator_psq_weights(const void* feature_transformer_ptr) {
    const auto& featureTransformer = *static_cast<const FeatureTransformer*>(feature_transformer_ptr);
    return &featureTransformer.weights[0];
}

const std::int32_t* zfish_accumulator_psq_psqt_weights(const void* feature_transformer_ptr) {
    const auto& featureTransformer = *static_cast<const FeatureTransformer*>(feature_transformer_ptr);
    return &featureTransformer.psqtWeights[0];
}

const std::int8_t* zfish_accumulator_threat_weights(const void* feature_transformer_ptr) {
    const auto& featureTransformer = *static_cast<const FeatureTransformer*>(feature_transformer_ptr);
    return &featureTransformer.threatWeights[0];
}

const std::int32_t* zfish_accumulator_threat_psqt_weights(const void* feature_transformer_ptr) {
    const auto& featureTransformer = *static_cast<const FeatureTransformer*>(feature_transformer_ptr);
    return &featureTransformer.threatPsqtWeights[0];
}
}

}  // namespace Stockfish::Eval::NNUE
