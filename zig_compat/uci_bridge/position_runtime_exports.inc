std::uint64_t zfish_position_material_zobrist(std::uint8_t piece, std::size_t count_index) {
    return Stockfish::Zobrist::psq[piece][8 + count_index];
}

void zfish_position_init_runtime() {
    Stockfish::Position::init();
}

void zfish_bitboards_init() {
    Stockfish::Bitboards::init();
}
