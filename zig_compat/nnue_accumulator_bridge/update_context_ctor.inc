    AccumulatorUpdateContext(Color                               persp,
                             const FeatureTransformer&           ft,
                             const AccumulatorState<FeatureSet>& accF,
                             AccumulatorState<FeatureSet>&       accT) noexcept :
        perspective{persp},
        featureTransformer{ft},
        from{accF},
        to{accT} {}
