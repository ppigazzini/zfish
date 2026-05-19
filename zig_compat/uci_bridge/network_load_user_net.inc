void zfish_network_load_user_net(void*                network_ptr,
                                 const unsigned char* dir_ptr,
                                 std::size_t          dir_len,
                                 const unsigned char* path_ptr,
                                 std::size_t          path_len) {
    auto& network = *static_cast<Network*>(network_ptr);
    NetworkBridgeAccess::loadUserNet(network,
                                     std::string(reinterpret_cast<const char*>(dir_ptr), dir_len),
                                     std::string(reinterpret_cast<const char*>(path_ptr), path_len));
}
