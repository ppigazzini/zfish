    template<UpdateOperation... ops,
             typename... Ts,
             std::enable_if_t<is_all_same_v<IndexType, Ts...>, bool> = true>
    void apply(const Ts... indices) {
        constexpr IndexType Dimensions = FeatureTransformer::OutputDimensions;

        auto to_weight_vector = [&](const IndexType index) {
            return &featureTransformer.weights[index * Dimensions];
        };

        auto to_psqt_weight_vector = [&](const IndexType index) {
            return &featureTransformer.psqtWeights[index * PSQTBuckets];
        };

        fused_row_reduce<Vec16Wrapper, Dimensions, ops...>(from.accumulation[perspective].data(),
                                                           to.accumulation[perspective].data(),
                                                           to_weight_vector(indices)...);

        fused_row_reduce<Vec32Wrapper, PSQTBuckets, ops...>(
          from.psqtAccumulation[perspective].data(), to.psqtAccumulation[perspective].data(),
          to_psqt_weight_vector(indices)...);
    }
