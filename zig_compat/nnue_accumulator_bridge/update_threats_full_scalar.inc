    for (IndexType j = 0; j < Dimensions; ++j)
        accumulator.accumulation[perspective][j] = 0;

    for (std::size_t k = 0; k < PSQTBuckets; ++k)
        accumulator.psqtAccumulation[perspective][k] = 0;

    for (const auto index : active)
    {
        const IndexType offset = Dimensions * index;

        for (IndexType j = 0; j < Dimensions; ++j)
            accumulator.accumulation[perspective][j] +=
              featureTransformer.threatWeights[offset + j];

        for (std::size_t k = 0; k < PSQTBuckets; ++k)
            accumulator.psqtAccumulation[perspective][k] +=
              featureTransformer.threatPsqtWeights[index * PSQTBuckets + k];
    }
