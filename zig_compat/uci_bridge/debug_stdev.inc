void dbg_stdev_of(int64_t value, int slot) {
    ++stdev.at(slot)[0];
    stdev.at(slot)[1] += value;
    stdev.at(slot)[2] += value * value;
}
