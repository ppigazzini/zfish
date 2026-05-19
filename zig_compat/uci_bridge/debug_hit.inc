void dbg_hit_on(bool cond, int slot) {
    ++hit.at(slot)[0];
    if (cond)
        ++hit.at(slot)[1];
}
