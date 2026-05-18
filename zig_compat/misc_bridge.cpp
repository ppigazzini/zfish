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

#include "misc.h"

#include <array>
#include <atomic>
#include <cassert>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <limits>
#include <memory>
#include <mutex>
#include <sstream>

#include "types.h"

namespace {

struct Tie: public std::streambuf {

    Tie(std::streambuf* b, std::streambuf* l) :
        buf(b),
        logBuf(l) {}

    int sync() override { return logBuf->pubsync(), buf->pubsync(); }
    int overflow(int c) override { return log(buf->sputc(char(c)), "<< "); }
    int underflow() override { return buf->sgetc(); }
    int uflow() override { return log(buf->sbumpc(), ">> "); }

    std::streambuf *buf, *logBuf;

    int log(int c, const char* prefix) {
        static int last = '\n';

        if (last == '\n')
            logBuf->sputn(prefix, 3);

        return last = logBuf->sputc(char(c));
    }
};

class Logger {

    Logger() :
        in(std::cin.rdbuf(), file.rdbuf()),
        out(std::cout.rdbuf(), file.rdbuf()) {}
    ~Logger() { start(""); }

    std::ofstream file;
    Tie           in, out;

   public:
    static void start(const std::string& fname) {
        static Logger l;

        if (l.file.is_open())
        {
            std::cout.rdbuf(l.out.buf);
            std::cin.rdbuf(l.in.buf);
            l.file.close();
        }

        if (!fname.empty())
        {
            l.file.open(fname, std::ifstream::out);

            if (!l.file.is_open())
            {
                std::cerr << "Unable to open debug log file " << fname << std::endl;
                exit(EXIT_FAILURE);
            }

            std::cin.rdbuf(&l.in);
            std::cout.rdbuf(&l.out);
        }
    }
};

constexpr int MaxDebugSlots = 32;

template<size_t N>
struct DebugInfo {
    std::array<std::atomic<int64_t>, N> data = {0};

    [[nodiscard]] constexpr std::atomic<int64_t>& operator[](size_t index) {
        assert(index < N);
        return data[index];
    }

    constexpr DebugInfo& operator=(const DebugInfo& other) {
        for (size_t i = 0; i < N; i++)
            data[i].store(other.data[i].load());
        return *this;
    }
};

struct DebugExtremes: public DebugInfo<3> {
    DebugExtremes() {
        data[1] = std::numeric_limits<int64_t>::min();
        data[2] = std::numeric_limits<int64_t>::max();
    }
};

std::array<DebugInfo<2>, MaxDebugSlots>  hit;
std::array<DebugInfo<2>, MaxDebugSlots>  mean;
std::array<DebugInfo<3>, MaxDebugSlots>  stdev;
std::array<DebugInfo<6>, MaxDebugSlots>  correl;
std::array<DebugExtremes, MaxDebugSlots> extremes;

std::string take_string_and_free(const char* rendered) {
    if (!rendered)
        std::abort();

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

}  // namespace

extern "C" {
std::uint64_t zfish_misc_hash_bytes(const unsigned char* data_ptr, std::size_t data_len);
std::size_t   zfish_misc_str_to_size_t(const unsigned char* input_ptr, std::size_t input_len);
const char*   zfish_misc_read_file_to_string(const unsigned char* path_ptr, std::size_t path_len);
const char*   zfish_misc_remove_whitespace(const unsigned char* input_ptr, std::size_t input_len);
bool          zfish_misc_is_whitespace(const unsigned char* input_ptr, std::size_t input_len);
const char*   zfish_misc_get_binary_directory(const unsigned char* argv0_ptr, std::size_t argv0_len);
const char*   zfish_misc_get_working_directory();
const char*   zfish_misc_engine_info_text();
}

namespace Stockfish {

// Version and compiler reporting remain explicit in the bridge because they are
// tightly coupled to the C++ preprocessor and stream formatting surface.
namespace {
constexpr std::string_view version = "dev";
}

std::string engine_version_info() {
    std::stringstream ss;
    ss << "Stockfish " << version << std::setfill('0');

    if constexpr (version == "dev")
    {
        ss << "-";
#ifdef GIT_DATE
        ss << stringify(GIT_DATE);
#else
        constexpr std::string_view months("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec");

        std::string       month, day, year;
        std::stringstream date(__DATE__);

        date >> month >> day >> year;
        ss << year << std::setw(2) << std::setfill('0') << (1 + months.find(month) / 4)
           << std::setw(2) << std::setfill('0') << day;
#endif

        ss << "-";

#ifdef GIT_SHA
        ss << stringify(GIT_SHA);
#else
        ss << "nogit";
#endif
    }

    return ss.str();
}

std::string engine_info(bool to_uci) {
    return engine_version_info() + (to_uci ? "\nid author " : " by ")
         + "the Stockfish developers (see AUTHORS file)";
}

extern "C" const char* zfish_misc_engine_info_text() {
    const auto value = engine_info();
    auto*      buffer = static_cast<char*>(std::malloc(value.size() + 1));
    if (!buffer)
        return nullptr;

    std::memcpy(buffer, value.c_str(), value.size() + 1);
    return buffer;
}

std::string compiler_info() {

#define make_version_string(major, minor, patch) \
    stringify(major) "." stringify(minor) "." stringify(patch)

    std::string compiler = "\nCompiled by                : ";

#if defined(__INTEL_LLVM_COMPILER)
    compiler += "ICX ";
    compiler += stringify(__INTEL_LLVM_COMPILER);
#elif defined(__clang__)
    compiler += "clang++ ";
    compiler += make_version_string(__clang_major__, __clang_minor__, __clang_patchlevel__);
#elif _MSC_VER
    compiler += "MSVC ";
    compiler += "(version ";
    compiler += stringify(_MSC_FULL_VER) "." stringify(_MSC_BUILD);
    compiler += ")";
#elif defined(__e2k__) && defined(__LCC__)
    #define dot_ver2(n) \
        compiler += char('.'); \
        compiler += char('0' + (n) / 10); \
        compiler += char('0' + (n) % 10);

    compiler += "MCST LCC ";
    compiler += "(version ";
    compiler += std::to_string(__LCC__ / 100);
    dot_ver2(__LCC__ % 100) dot_ver2(__LCC_MINOR__) compiler += ")";
#elif __GNUC__
    compiler += "g++ (GNUC) ";
    compiler += make_version_string(__GNUC__, __GNUC_MINOR__, __GNUC_PATCHLEVEL__);
#else
    compiler += "Unknown compiler ";
    compiler += "(unknown version)";
#endif

#if defined(__APPLE__)
    compiler += " on Apple";
#elif defined(__CYGWIN__)
    compiler += " on Cygwin";
#elif defined(__MINGW64__)
    compiler += " on MinGW64";
#elif defined(__MINGW32__)
    compiler += " on MinGW32";
#elif defined(__ANDROID__)
    compiler += " on Android";
#elif defined(__linux__)
    compiler += " on Linux";
#elif defined(_WIN64)
    compiler += " on Microsoft Windows 64-bit";
#elif defined(_WIN32)
    compiler += " on Microsoft Windows 32-bit";
#else
    compiler += " on unknown system";
#endif

    compiler += "\nCompilation architecture   : ";
#if defined(ARCH)
    compiler += stringify(ARCH);
#else
    compiler += "(undefined architecture)";
#endif

    compiler += "\nCompilation settings       : ";
    compiler += (Is64Bit ? "64bit" : "32bit");
#if defined(USE_AVX512ICL)
    compiler += " AVX512ICL";
#endif
#if defined(USE_VNNI)
    compiler += " VNNI";
#endif
#if defined(USE_AVX512)
    compiler += " AVX512";
#endif
    compiler += (HasPext ? " BMI2" : "");
#if defined(USE_AVX2)
    compiler += " AVX2";
#endif
#if defined(USE_SSE41)
    compiler += " SSE41";
#endif
#if defined(USE_SSSE3)
    compiler += " SSSE3";
#endif
#if defined(USE_SSE2)
    compiler += " SSE2";
#endif
#if defined(USE_NEON_DOTPROD)
    compiler += " NEON_DOTPROD";
#elif defined(USE_NEON)
    compiler += " NEON";
#endif
    compiler += (HasPopCnt ? " POPCNT" : "");

#if !defined(NDEBUG)
    compiler += " DEBUG";
#endif

    compiler += "\nCompiler __VERSION__ macro : ";
#ifdef __VERSION__
    compiler += __VERSION__;
#else
    compiler += "(undefined macro)";
#endif

    compiler += "\n";

    return compiler;
}

void dbg_hit_on(bool cond, int slot) {
    ++hit.at(slot)[0];
    if (cond)
        ++hit.at(slot)[1];
}

void dbg_mean_of(int64_t value, int slot) {
    ++mean.at(slot)[0];
    mean.at(slot)[1] += value;
}

void dbg_stdev_of(int64_t value, int slot) {
    ++stdev.at(slot)[0];
    stdev.at(slot)[1] += value;
    stdev.at(slot)[2] += value * value;
}

void dbg_extremes_of(int64_t value, int slot) {
    ++extremes.at(slot)[0];

    int64_t current_max = extremes.at(slot)[1].load();
    while (current_max < value && !extremes.at(slot)[1].compare_exchange_weak(current_max, value))
    {}

    int64_t current_min = extremes.at(slot)[2].load();
    while (current_min > value && !extremes.at(slot)[2].compare_exchange_weak(current_min, value))
    {}
}

void dbg_correl_of(int64_t value1, int64_t value2, int slot) {
    ++correl.at(slot)[0];
    correl.at(slot)[1] += value1;
    correl.at(slot)[2] += value1 * value1;
    correl.at(slot)[3] += value2;
    correl.at(slot)[4] += value2 * value2;
    correl.at(slot)[5] += value1 * value2;
}

void dbg_print() {
    int64_t n;
    auto    E   = [&n](int64_t x) { return double(x) / n; };
    auto    sqr = [](double x) { return x * x; };

    for (int i = 0; i < MaxDebugSlots; ++i)
        if ((n = hit[i][0]))
            std::cerr << "Hit #" << i << ": Total " << n << " Hits " << hit[i][1]
                      << " Hit Rate (%) " << 100.0 * E(hit[i][1]) << std::endl;

    for (int i = 0; i < MaxDebugSlots; ++i)
        if ((n = mean[i][0]))
            std::cerr << "Mean #" << i << ": Total " << n << " Mean " << E(mean[i][1])
                      << std::endl;

    for (int i = 0; i < MaxDebugSlots; ++i)
        if ((n = stdev[i][0]))
        {
            double r = sqrt(E(stdev[i][2]) - sqr(E(stdev[i][1])));
            std::cerr << "Stdev #" << i << ": Total " << n << " Stdev " << r << std::endl;
        }

    for (int i = 0; i < MaxDebugSlots; ++i)
        if ((n = extremes[i][0]))
            std::cerr << "Extremity #" << i << ": Total " << n << " Min " << extremes[i][2]
                      << " Max " << extremes[i][1] << std::endl;

    for (int i = 0; i < MaxDebugSlots; ++i)
        if ((n = correl[i][0]))
        {
            double r = (E(correl[i][5]) - E(correl[i][1]) * E(correl[i][3]))
                     / (sqrt(E(correl[i][2]) - sqr(E(correl[i][1])))
                        * sqrt(E(correl[i][4]) - sqr(E(correl[i][3]))));
            std::cerr << "Correl. #" << i << ": Total " << n << " Coefficient " << r << std::endl;
        }
}

void dbg_clear() {
    hit.fill({});
    mean.fill({});
    stdev.fill({});
    correl.fill({});
    extremes.fill({});
}

std::ostream& operator<<(std::ostream& os, SyncCout sc) {
    static std::mutex m;

    if (sc == IO_LOCK)
        m.lock();

    if (sc == IO_UNLOCK)
        m.unlock();

    return os;
}

void sync_cout_start() { std::cout << IO_LOCK; }
void sync_cout_end() { std::cout << IO_UNLOCK; }

std::uint64_t hash_bytes(const char* data, size_t size) {
    return zfish_misc_hash_bytes(reinterpret_cast<const unsigned char*>(data), size);
}

void start_logger(const std::string& fname) { Logger::start(fname); }

size_t str_to_size_t(const std::string& s) {
    return zfish_misc_str_to_size_t(reinterpret_cast<const unsigned char*>(s.data()), s.size());
}

std::optional<std::string> read_file_to_string(const std::string& path) {
    const char* rendered =
      zfish_misc_read_file_to_string(reinterpret_cast<const unsigned char*>(path.data()), path.size());
    if (!rendered)
        return std::nullopt;

    return take_string_and_free(rendered);
}

void remove_whitespace(std::string& s) {
    const char* rendered =
      zfish_misc_remove_whitespace(reinterpret_cast<const unsigned char*>(s.data()), s.size());
    s = take_string_and_free(rendered);
}

bool is_whitespace(std::string_view s) {
    return zfish_misc_is_whitespace(reinterpret_cast<const unsigned char*>(s.data()), s.size());
}

std::string CommandLine::get_binary_directory(std::string argv0) {
    const char* rendered = zfish_misc_get_binary_directory(
      reinterpret_cast<const unsigned char*>(argv0.data()), argv0.size());
    return take_string_and_free(rendered);
}

std::string CommandLine::get_working_directory() {
    return take_string_and_free(zfish_misc_get_working_directory());
}

}  // namespace Stockfish
