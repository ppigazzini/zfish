void dbg_mean_of(int64_t value, int slot) {
    ++mean.at(slot)[0];
    mean.at(slot)[1] += value;
}
