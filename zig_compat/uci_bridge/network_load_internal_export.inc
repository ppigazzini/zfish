void zfish_network_load_internal(void* network_ptr) {
    auto& network = *static_cast<Network*>(network_ptr);
    NetworkBridgeAccess::loadInternal(network);
}
