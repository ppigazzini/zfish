    std::ifstream stream(dir + evalfilePath, std::ios::binary);
    auto          description = load(stream);
