template<typename FeatureSet>
auto make_accumulator_update_context(Color                               perspective,
                                     const FeatureTransformer&           featureTransformer,
                                     const AccumulatorState<FeatureSet>& accumulatorFrom,
                                     AccumulatorState<FeatureSet>&       accumulatorTo) noexcept {
    return AccumulatorUpdateContext<FeatureSet>{perspective, featureTransformer, accumulatorFrom,
                                                accumulatorTo};
}
