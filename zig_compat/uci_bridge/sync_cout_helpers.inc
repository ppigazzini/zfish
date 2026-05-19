void sync_cout_start() { std::cout << IO_LOCK; }
void sync_cout_end() { std::cout << IO_UNLOCK; }
