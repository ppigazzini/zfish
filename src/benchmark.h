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

#ifndef BENCHMARK_H_INCLUDED
#define BENCHMARK_H_INCLUDED

#include <cstdlib>
#include <istream>
#include <iosfwd>
#include <string>
#include <vector>

#if defined(ZFISH_ZIG_BUILD)
  #include "misc.h"
  #include "numa.h"

extern "C" {
struct ZfishBenchmarkSetupOutput {
    int         tt_size;
    int         threads;
    const char* commands_ptr;
    const char* original_invocation_ptr;
    const char* filled_invocation_ptr;
};

const char* zfish_benchmark_setup_bench(const unsigned char* current_fen_ptr,
                                        std::size_t          current_fen_len,
                                        const unsigned char* args_ptr,
                                        std::size_t          args_len);
ZfishBenchmarkSetupOutput zfish_benchmark_setup_benchmark(const unsigned char* args_ptr,
                                                          std::size_t          args_len,
                                                          int                  hardware_concurrency);
}
#endif

namespace Stockfish::Benchmark {

std::vector<std::string> setup_bench(const std::string&, std::istream&);

struct BenchmarkSetup {
    int                      ttSize;
    int                      threads;
    std::vector<std::string> commands;
    std::string              originalInvocation;
    std::string              filledInvocation;
};

BenchmarkSetup setup_benchmark(std::istream&);

#if defined(ZFISH_ZIG_BUILD)
inline std::string take_zig_benchmark_string_and_free(const char* rendered) {
  if (!rendered)
    return {};

  std::string value(rendered);
  std::free(const_cast<char*>(rendered));
  return value;
}

inline std::vector<std::string> setup_bench(const std::string& current_fen, std::istream& args) {
  std::string benchmark_args;
  std::getline(args, benchmark_args);

  const auto rendered = take_zig_benchmark_string_and_free(zfish_benchmark_setup_bench(
    reinterpret_cast<const unsigned char*>(current_fen.data()), current_fen.size(),
    reinterpret_cast<const unsigned char*>(benchmark_args.data()), benchmark_args.size()));

  std::vector<std::string> list;
  for (const auto line : Stockfish::split(rendered, "\n"))
    list.emplace_back(line);

  return list;
}

inline BenchmarkSetup setup_benchmark(std::istream& args) {
  std::string benchmark_args;
  std::getline(args, benchmark_args);

  const auto setup_output = zfish_benchmark_setup_benchmark(
    reinterpret_cast<const unsigned char*>(benchmark_args.data()), benchmark_args.size(),
    static_cast<int>(Stockfish::get_hardware_concurrency()));

  BenchmarkSetup setup{};
  setup.ttSize             = setup_output.tt_size;
  setup.threads            = setup_output.threads;
  setup.originalInvocation = take_zig_benchmark_string_and_free(setup_output.original_invocation_ptr);
  setup.filledInvocation   = take_zig_benchmark_string_and_free(setup_output.filled_invocation_ptr);

  const auto commands_text = take_zig_benchmark_string_and_free(setup_output.commands_ptr);
  for (const auto command : Stockfish::split(commands_text, "\n"))
    setup.commands.emplace_back(command);

  return setup;
}
#endif

}  // namespace Stockfish

#endif  // #ifndef BENCHMARK_H_INCLUDED
