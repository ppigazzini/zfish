std::size_t zfish_network_piece_count(const void* pos_ptr) {
    return static_cast<const Position*>(pos_ptr)->count<ALL_PIECES>();
}
