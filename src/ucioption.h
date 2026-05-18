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

#ifndef UCIOPTION_H_INCLUDED
#define UCIOPTION_H_INCLUDED

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iosfwd>
#include <istream>
#include <map>
#include <optional>
#include <sstream>
#include <string>

#if defined(ZFISH_ZIG_BUILD)
  #include "misc.h"

extern "C" {
struct ZfishParsedSetOption {
    const char* name;
    const char* value;
};

struct ZfishAssignmentResult {
  std::uint8_t accepted;
    const char* normalized_value;
};

bool zfish_option_case_insensitive_less(const unsigned char* left_ptr,
                                        std::size_t          left_len,
                                        const unsigned char* right_ptr,
                                        std::size_t          right_len);
ZfishParsedSetOption zfish_option_parse_setoption(const unsigned char* input_ptr,
                                                  std::size_t          input_len);
bool zfish_option_combo_equals(const unsigned char* current_ptr,
                               std::size_t          current_len,
                               const unsigned char* value_ptr,
                               std::size_t          value_len);
ZfishAssignmentResult zfish_option_validate_assignment(const unsigned char* type_ptr,
                                                       std::size_t          type_len,
                                                       const unsigned char* value_ptr,
                                                       std::size_t          value_len,
                                                       int                  min_value,
                                                       int                  max_value,
                                                       const unsigned char* default_ptr,
                                                       std::size_t          default_len);
}
#endif

namespace Stockfish {
// Define a custom comparator, because the UCI options should be case-insensitive
struct CaseInsensitiveLess {
    bool operator()(const std::string&, const std::string&) const;
};

class OptionsMap;

// The Option class implements each option as specified by the UCI protocol
class Option {
   public:
    using OnChange = std::function<std::optional<std::string>(const Option&)>;

    Option(const OptionsMap*);
    Option(OnChange = nullptr);
    Option(bool v, OnChange = nullptr);
    Option(const char* v, OnChange = nullptr);
    Option(int v, int minv, int maxv, OnChange = nullptr);
    Option(const char* v, const char* cur, OnChange = nullptr);

    Option& operator=(const std::string&);
    operator int() const;
    operator std::string() const;
    bool operator==(const char*) const;
    bool operator!=(const char*) const;

    friend std::ostream& operator<<(std::ostream&, const OptionsMap&);

    int operator<<(const Option&) = delete;

   private:
    friend class OptionsMap;
    friend class Engine;
    friend class Tune;


    std::string       defaultValue, currentValue, type;
    int               min, max;
    size_t            idx;
    OnChange          on_change;
    const OptionsMap* parent = nullptr;
};

class OptionsMap {
   public:
    using InfoListener = std::function<void(std::optional<std::string>)>;

    OptionsMap()                             = default;
    OptionsMap(const OptionsMap&)            = delete;
    OptionsMap(OptionsMap&&)                 = delete;
    OptionsMap& operator=(const OptionsMap&) = delete;
    OptionsMap& operator=(OptionsMap&&)      = delete;

    void add_info_listener(InfoListener&&);

    void setoption(std::istringstream&);

    const Option& operator[](const std::string&) const;

    void add(const std::string&, const Option& option);

    std::size_t count(const std::string&) const;

   private:
    friend class Engine;
    friend class Option;

    friend std::ostream& operator<<(std::ostream&, const OptionsMap&);

    // The options container is defined as a std::map
    using OptionsStore = std::map<std::string, Option, CaseInsensitiveLess>;

    OptionsStore options_map;
    InfoListener info;
};

  #if defined(ZFISH_ZIG_BUILD)
  inline std::string take_zig_option_string_and_free(const char* rendered) {
    if (!rendered)
      return {};

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
  }

  inline bool CaseInsensitiveLess::operator()(const std::string& left, const std::string& right) const {
    return zfish_option_case_insensitive_less(
      reinterpret_cast<const unsigned char*>(left.data()), left.size(),
      reinterpret_cast<const unsigned char*>(right.data()), right.size());
  }

  inline void OptionsMap::setoption(std::istringstream& is) {
    std::string rest;
    std::getline(is, rest);

    const auto parsed = zfish_option_parse_setoption(
      reinterpret_cast<const unsigned char*>(rest.data()), rest.size());
    const auto name  = take_zig_option_string_and_free(parsed.name);
    const auto value = take_zig_option_string_and_free(parsed.value);

    if (options_map.count(name))
      options_map[name] = value;
    else
      sync_cout << "No such option: " << name << sync_endl;
  }

  inline bool Option::operator==(const char* value) const {
    assert(type == "combo");
    return zfish_option_combo_equals(
      reinterpret_cast<const unsigned char*>(currentValue.data()), currentValue.size(),
      reinterpret_cast<const unsigned char*>(value), std::char_traits<char>::length(value));
  }

  inline Option& Option::operator=(const std::string& value) {
    assert(!type.empty());

    const auto result = zfish_option_validate_assignment(
      reinterpret_cast<const unsigned char*>(type.data()), type.size(),
      reinterpret_cast<const unsigned char*>(value.data()), value.size(), min, max,
      reinterpret_cast<const unsigned char*>(defaultValue.data()), defaultValue.size());

    if (!result.accepted)
      return *this;

    if (type != "button")
      currentValue = take_zig_option_string_and_free(result.normalized_value);

    if (on_change)
    {
      const auto ret = on_change(*this);

      if (ret && parent != nullptr && parent->info != nullptr)
        parent->info(ret);
    }

    return *this;
  }
  #endif

}
#endif  // #ifndef UCIOPTION_H_INCLUDED
