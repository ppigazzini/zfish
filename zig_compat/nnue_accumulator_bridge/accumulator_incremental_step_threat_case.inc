                if (forward)
                        AccumulatorBridgeAccess::incrementalThreatStep<true>(
                            stack, side, pos, featureTransformer, target_index, computed_index);
                else
                        AccumulatorBridgeAccess::incrementalThreatStep<false>(
                            stack, side, pos, featureTransformer, target_index, computed_index);
                return;
