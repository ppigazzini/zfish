        constexpr IndexType Dimensions = FeatureTransformer::OutputDimensions;

        const auto& fromAcc = from.accumulation[perspective];
        auto&       toAcc   = to.accumulation[perspective];

        const auto& fromPsqtAcc = from.psqtAccumulation[perspective];
        auto&       toPsqtAcc   = to.psqtAccumulation[perspective];
