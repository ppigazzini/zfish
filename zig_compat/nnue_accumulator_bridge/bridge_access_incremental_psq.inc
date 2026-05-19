        template<bool Forward>
        static void incrementalPsqStep(AccumulatorStack&         stack,
                                                                     Color                     perspective,
                                                                     const Position&           pos,
                                                                     const FeatureTransformer& featureTransformer,
                                                                     std::size_t               target_index,
                                                                     std::size_t               computed_index) {
                update_accumulator_incremental<Forward, PSQFeatureSet>(
                    perspective, featureTransformer, pos.square<KING>(perspective),
                    stack.mut_accumulators<PSQFeatureSet>()[target_index],
                    stack.accumulators<PSQFeatureSet>()[computed_index]);
        }
