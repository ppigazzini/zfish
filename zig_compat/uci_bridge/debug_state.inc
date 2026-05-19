constexpr int MaxDebugSlots = 32;

template<size_t N>
struct DebugInfo {
    std::array<std::atomic<int64_t>, N> data = {0};

    [[nodiscard]] constexpr std::atomic<int64_t>& operator[](size_t index) {
        assert(index < N);
        return data[index];
    }

    constexpr DebugInfo& operator=(const DebugInfo& other) {
        for (size_t i = 0; i < N; i++)
            data[i].store(other.data[i].load());
        return *this;
    }
};

struct DebugExtremes: public DebugInfo<3> {
    DebugExtremes() {
        data[1] = std::numeric_limits<int64_t>::min();
        data[2] = std::numeric_limits<int64_t>::max();
    }
};

std::array<DebugInfo<2>, MaxDebugSlots>  hit;
std::array<DebugInfo<2>, MaxDebugSlots>  mean;
std::array<DebugInfo<3>, MaxDebugSlots>  stdev;
std::array<DebugInfo<6>, MaxDebugSlots>  correl;
std::array<DebugExtremes, MaxDebugSlots> extremes;
