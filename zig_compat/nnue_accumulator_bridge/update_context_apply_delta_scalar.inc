
        toAcc     = fromAcc;
        toPsqtAcc = fromPsqtAcc;

        for (const auto index : removed)
        {
            const IndexType offset = Dimensions * index;

            for (IndexType j = 0; j < Dimensions; ++j)
                toAcc[j] -= featureTransformer.threatWeights[offset + j];

            for (std::size_t k = 0; k < PSQTBuckets; ++k)
                toPsqtAcc[k] -= featureTransformer.threatPsqtWeights[index * PSQTBuckets + k];
        }

        for (const auto index : added)
        {
            const IndexType offset = Dimensions * index;

            for (IndexType j = 0; j < Dimensions; ++j)
                toAcc[j] += featureTransformer.threatWeights[offset + j];

            for (std::size_t k = 0; k < PSQTBuckets; ++k)
                toPsqtAcc[k] += featureTransformer.threatPsqtWeights[index * PSQTBuckets + k];
        }
