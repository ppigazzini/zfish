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

#include "benchmark.h"

#include <cstdlib>
#include <istream>
#include <string>
#include <string_view>
#include <vector>

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

namespace {

std::string read_remaining_args(std::istream& is) {
    std::string args;
    std::getline(is, args);
    return args;
}

std::vector<std::string> split_lines_and_free(const char* rendered) {
    if (!rendered)
        std::abort();

    std::vector<std::string> lines;
    std::string_view         view(rendered);
    std::size_t              start = 0;

    while (start <= view.size())
    {
        const auto end  = view.find('\n', start);
        const auto stop = end == std::string_view::npos ? view.size() : end;

        if (stop > start)
            lines.emplace_back(view.substr(start, stop - start));

        if (end == std::string_view::npos)
            break;

        start = end + 1;
    }

    std::free(const_cast<char*>(rendered));
    return lines;
}

std::string take_string_and_free(const char* rendered) {
    if (!rendered)
        std::abort();

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

}  // namespace

namespace Stockfish::Benchmark {

std::vector<std::string> setup_bench(const std::string& currentFen, std::istream& is) {
    const std::string args = read_remaining_args(is);
    const char*       rendered = zfish_benchmark_setup_bench(
      reinterpret_cast<const unsigned char*>(currentFen.data()), currentFen.size(),
      reinterpret_cast<const unsigned char*>(args.data()), args.size());

    return split_lines_and_free(rendered);
}

BenchmarkSetup setup_benchmark(std::istream& is) {
    const std::string args = read_remaining_args(is);
    const auto        output = zfish_benchmark_setup_benchmark(
      reinterpret_cast<const unsigned char*>(args.data()), args.size(),
      static_cast<int>(get_hardware_concurrency()));

    BenchmarkSetup setup{};
    setup.ttSize             = output.tt_size;
    setup.threads            = output.threads;
    setup.commands           = split_lines_and_free(output.commands_ptr);
    setup.originalInvocation = take_string_and_free(output.original_invocation_ptr);
    setup.filledInvocation   = take_string_and_free(output.filled_invocation_ptr);
    return setup;
}

}  // namespace Stockfish::Benchmark
