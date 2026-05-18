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

#include <cstdlib>
#include <string>

#define ZFISH_TBPROBE_BRIDGE_SKIP_DTZ_BEFORE_ZEROING
#define ZFISH_TBPROBE_BRIDGE_SKIP_ADD
#include "../src/syzygy/tbprobe.cpp"

extern "C" {
const char* zfish_tbprobe_build_code(const unsigned char* piece_types_ptr, std::size_t piece_count);
int         zfish_tbprobe_dtz_before_zeroing(int wdl);
}

namespace Stockfish {

namespace {

std::string take_string_and_free(const char* rendered) {
    if (!rendered)
        std::abort();

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

int dtz_before_zeroing(WDLScore wdl) { return zfish_tbprobe_dtz_before_zeroing(int(wdl)); }

void TBTables::add(const std::vector<PieceType>& pieces) {
    const std::string code = take_string_and_free(
      zfish_tbprobe_build_code(reinterpret_cast<const unsigned char*>(pieces.data()), pieces.size()));

    TBFile file_dtz(code + ".rtbz");
    if (file_dtz.is_open())
    {
        file_dtz.close();
        foundDTZFiles++;
    }

    TBFile file(code + ".rtbw");

    if (!file.is_open())
        return;

    file.close();
    foundWDLFiles++;

    MaxCardinality = std::max(int(pieces.size()), MaxCardinality);

    wdlTable.emplace_back(code);
    dtzTable.emplace_back(wdlTable.back());

    insert(wdlTable.back().key, &wdlTable.back(), &dtzTable.back());
    insert(wdlTable.back().key2, &wdlTable.back(), &dtzTable.back());
}

}  // namespace

}  // namespace Stockfish
