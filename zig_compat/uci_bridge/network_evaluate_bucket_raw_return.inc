    const auto positional = NetworkBridgeAccess::layer(network, bucket).propagate(transformedFeatures);
    return {static_cast<int>(psqt), static_cast<int>(positional)};
