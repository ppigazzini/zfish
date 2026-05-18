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

#include "tune.h"

#include <algorithm>
#include <iostream>
#include <map>
#include <optional>
#include <string>

#include "ucioption.h"

using std::string;

extern "C" {
struct ZfishTuneNextResult {
    const char* token;
    const char* remaining;
};

ZfishTuneNextResult zfish_tune_next(const unsigned char* names_ptr,
                                    std::size_t          names_len,
                                    std::uint8_t         pop);
bool                zfish_tune_should_make_option(int min_value, int max_value);
}

namespace Stockfish {

bool          Tune::update_on_last;
const Option* LastOption = nullptr;
OptionsMap*   Tune::options;

namespace {
std::map<std::string, int> TuneResults;

std::string take_string_and_free(const char* rendered) {
    if (!rendered)
        return {};

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

std::optional<std::string> on_tune(const Option& o) {
    if (!Tune::update_on_last || LastOption == &o)
        Tune::read_options();

    return std::nullopt;
}
}  // namespace

void Tune::make_option(OptionsMap* opts, const string& n, int v, const SetRange& r) {
    const auto bounds = r(v);
    if (!zfish_tune_should_make_option(bounds.first, bounds.second))
        return;

    if (TuneResults.count(n))
        v = TuneResults[n];

    opts->add(n, Option(v, bounds.first, bounds.second, on_tune));
    LastOption = &((*opts)[n]);

    std::cout << n << ","                                  //
              << v << ","                                  //
              << bounds.first << ","                       //
              << bounds.second << ","                      //
              << (bounds.second - bounds.first) / 20.0 << ","  //
              << "0.0020" << std::endl;
}

string Tune::next(string& names, bool pop) {
    const auto result = zfish_tune_next(reinterpret_cast<const unsigned char*>(names.data()),
                                        names.size(), static_cast<std::uint8_t>(pop ? 1 : 0));
    const auto token = take_string_and_free(result.token);
    names            = take_string_and_free(result.remaining);
    return token;
}

template<>
void Tune::Entry<int>::init_option() {
    make_option(options, name, value, range);
}

template<>
void Tune::Entry<int>::read_option() {
    if (options->count(name))
        value = int((*options)[name]);
}

template<>
void Tune::Entry<Tune::PostUpdate>::init_option() {}

template<>
void Tune::Entry<Tune::PostUpdate>::read_option() {
    value();
}

void Tune::read_results() { /* ...insert your values here... */ }

}  // namespace Stockfish
