                if (forward)
                        AccumulatorBridgeAccess::incrementalPsqStep<true>(
                            stack, side, pos, featureTransformer, target_index, computed_index);
                else
                        AccumulatorBridgeAccess::incrementalPsqStep<false>(
                            stack, side, pos, featureTransformer, target_index, computed_index);
                return;
