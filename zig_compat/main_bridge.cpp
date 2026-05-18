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

#include <iostream>
#include <memory>
#include <vector>

#include "bitboard.h"
#include "misc.h"
#include "position.h"
#include "tune.h"
#include "uci.h"

using namespace Stockfish;

extern "C" int zfish_main_run(int argc, const char* const* argv) {
    std::vector<char*> mutable_argv(static_cast<size_t>(argc));
    for (int i = 0; i < argc; ++i)
        mutable_argv[static_cast<size_t>(i)] = const_cast<char*>(argv[i]);

    std::cout << engine_info() << std::endl;

    Bitboards::init();
    Position::init();

    auto uci = std::make_unique<UCIEngine>(argc, mutable_argv.data());

    Tune::init(uci->engine_options());

    uci->loop();

    return 0;
}
