/*
  Stockfish, a UCI chess playing engine derived from Glaurung 2.1
  Copyright (C) 2004-2026 The Stockfish developers (see AUTHORS file)

  Stockfish is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  Stockfish is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

#include "memory.h"

extern "C" {
void* zfish_std_aligned_alloc(size_t alignment, size_t size);
void  zfish_std_aligned_free(void* ptr);
void* zfish_aligned_large_pages_alloc(size_t size);
void  zfish_aligned_large_pages_free(void* ptr);
bool  zfish_has_large_pages();
}

namespace Stockfish {

void* std_aligned_alloc(size_t alignment, size_t size) {
    return zfish_std_aligned_alloc(alignment, size);
}

void std_aligned_free(void* ptr) { zfish_std_aligned_free(ptr); }

void* aligned_large_pages_alloc(size_t allocSize) {
    return zfish_aligned_large_pages_alloc(allocSize);
}

void aligned_large_pages_free(void* mem) { zfish_aligned_large_pages_free(mem); }

bool has_large_pages() { return zfish_has_large_pages(); }

}  // namespace Stockfish
