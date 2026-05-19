bool zfish_network_save_named(const void*          network_ptr,
                              const unsigned char* filename_ptr,
                              std::size_t          filename_len) {
    const auto& network = *static_cast<const Network*>(network_ptr);
    const auto  actualFilename = std::string(reinterpret_cast<const char*>(filename_ptr), filename_len);
    std::ofstream stream(actualFilename, std::ios_base::binary);
    const auto& eval_file = NetworkBridgeAccess::evalFile(network);
    return NetworkBridgeAccess::saveNamed(network, stream, eval_file.current, eval_file.netDescription);
}
