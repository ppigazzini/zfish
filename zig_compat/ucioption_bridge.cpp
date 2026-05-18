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

#include "ucioption.h"

#include <algorithm>
#include <cassert>
#include <cctype>
#include <cstdlib>
#include <iostream>
#include <sstream>
#include <utility>

#include "misc.h"

extern "C" {
struct ZfishParsedSetOption {
    const char* name;
    const char* value;
};

struct ZfishAssignmentResult {
    std::uint8_t accepted;
    const char*  normalized_value;
};

bool                zfish_option_case_insensitive_less(const unsigned char* left_ptr,
                                                       std::size_t          left_len,
                                                       const unsigned char* right_ptr,
                                                       std::size_t          right_len);
ZfishParsedSetOption zfish_option_parse_setoption(const unsigned char* input_ptr,
                                                  std::size_t          input_len);
bool                zfish_option_combo_equals(const unsigned char* current_ptr,
                                              std::size_t          current_len,
                                              const unsigned char* query_ptr,
                                              std::size_t          query_len);
ZfishAssignmentResult zfish_option_validate_assignment(const unsigned char* type_ptr,
                                                       std::size_t          type_len,
                                                       const unsigned char* value_ptr,
                                                       std::size_t          value_len,
                                                       int                  min_value,
                                                       int                  max_value,
                                                       const unsigned char* default_ptr,
                                                       std::size_t          default_len);
}

namespace {

std::string take_string_and_free(const char* rendered) {
    if (!rendered)
        return {};

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

}  // namespace

namespace Stockfish {

bool CaseInsensitiveLess::operator()(const std::string& s1, const std::string& s2) const {
    return zfish_option_case_insensitive_less(reinterpret_cast<const unsigned char*>(s1.data()), s1.size(),
                                              reinterpret_cast<const unsigned char*>(s2.data()), s2.size());
}

void OptionsMap::add_info_listener(InfoListener&& message_func) { info = std::move(message_func); }

void OptionsMap::setoption(std::istringstream& is) {
    std::string rest;
    std::getline(is, rest);

    const auto parsed = zfish_option_parse_setoption(
      reinterpret_cast<const unsigned char*>(rest.data()), rest.size());
    const auto name  = take_string_and_free(parsed.name);
    const auto value = take_string_and_free(parsed.value);

    if (options_map.count(name))
        options_map[name] = value;
    else
        sync_cout << "No such option: " << name << sync_endl;
}

const Option& OptionsMap::operator[](const std::string& name) const {
    auto it = options_map.find(name);
    assert(it != options_map.end());
    return it->second;
}

void OptionsMap::add(const std::string& name, const Option& option) {
    if (!options_map.count(name))
    {
        static size_t insert_order = 0;

        options_map[name] = option;

        options_map[name].parent = this;
        options_map[name].idx    = insert_order++;
    }
    else
    {
        std::cerr << "Option \"" << name << "\" was already added!" << std::endl;
        std::exit(EXIT_FAILURE);
    }
}

std::size_t OptionsMap::count(const std::string& name) const { return options_map.count(name); }

Option::Option(const OptionsMap* map) :
    parent(map) {}

Option::Option(const char* v, OnChange f) :
    type("string"),
    min(0),
    max(0),
    on_change(std::move(f)) {
    defaultValue = currentValue = v;
}

Option::Option(bool v, OnChange f) :
    type("check"),
    min(0),
    max(0),
    on_change(std::move(f)) {
    defaultValue = currentValue = (v ? "true" : "false");
}

Option::Option(OnChange f) :
    type("button"),
    min(0),
    max(0),
    on_change(std::move(f)) {}

Option::Option(int v, int minv, int maxv, OnChange f) :
    type("spin"),
    min(minv),
    max(maxv),
    on_change(std::move(f)) {
    defaultValue = currentValue = std::to_string(v);
}

Option::Option(const char* v, const char* cur, OnChange f) :
    type("combo"),
    min(0),
    max(0),
    on_change(std::move(f)) {
    defaultValue = v;
    currentValue = cur;
}

Option::operator int() const {
    assert(type == "check" || type == "spin");
    return (type == "spin" ? std::stoi(currentValue) : currentValue == "true");
}

Option::operator std::string() const {
    assert(type == "string");
    return currentValue;
}

bool Option::operator==(const char* s) const {
    assert(type == "combo");
    return zfish_option_combo_equals(reinterpret_cast<const unsigned char*>(currentValue.data()),
                                     currentValue.size(), reinterpret_cast<const unsigned char*>(s),
                                     std::char_traits<char>::length(s));
}

bool Option::operator!=(const char* s) const { return !(*this == s); }

Option& Option::operator=(const std::string& v) {
    assert(!type.empty());

    const auto result = zfish_option_validate_assignment(
      reinterpret_cast<const unsigned char*>(type.data()), type.size(),
      reinterpret_cast<const unsigned char*>(v.data()), v.size(), min, max,
      reinterpret_cast<const unsigned char*>(defaultValue.data()), defaultValue.size());

    if (!result.accepted)
        return *this;

    if (type != "button")
        currentValue = take_string_and_free(result.normalized_value);

    if (on_change)
    {
        const auto ret = on_change(*this);

        if (ret && parent != nullptr && parent->info != nullptr)
            parent->info(ret);
    }

    return *this;
}

std::ostream& operator<<(std::ostream& os, const OptionsMap& om) {
    for (size_t idx = 0; idx < om.options_map.size(); ++idx)
        for (const auto& it : om.options_map)
            if (it.second.idx == idx)
            {
                const Option& o = it.second;
                os << "\noption name " << it.first << " type " << o.type;

                if (o.type == "check" || o.type == "combo")
                    os << " default " << o.defaultValue;
                else if (o.type == "string")
                    os << " default " << (o.defaultValue.empty() ? "<empty>" : o.defaultValue);
                else if (o.type == "spin")
                    os << " default " << stoi(o.defaultValue) << " min " << o.min << " max " << o.max;

                break;
            }

    return os;
}

}  // namespace Stockfish
