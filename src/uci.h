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

#ifndef UCI_H_INCLUDED
#define UCI_H_INCLUDED

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <string_view>

#include "engine.h"
#include "misc.h"
#include "score.h"
#include "search.h"

#if defined(ZFISH_ZIG_BUILD)
extern "C" {
struct ZfishParsedLimits {
    std::int64_t  wtime;
    std::int64_t  btime;
    std::int64_t  winc;
    std::int64_t  binc;
    int           movestogo;
    int           depth;
    int           mate;
    int           perft;
    int           infinite;
    std::int64_t  movetime;
    std::uint64_t nodes;
    std::uint8_t  ponder_mode;
    const char*   searchmoves;
};

struct ZfishParsedPosition {
    std::uint8_t ok;
    const char*  fen;
    const char*  moves;
};

ZfishParsedLimits zfish_uci_parse_limits(const unsigned char* input_ptr, std::size_t input_len);
ZfishParsedPosition zfish_uci_parse_position(const unsigned char* input_ptr, std::size_t input_len);
const char* zfish_uci_help_text();
const char* zfish_uci_format_unknown_command(const unsigned char* command_ptr,
                                             std::size_t          command_len);
const char* zfish_uci_format_info_string(const unsigned char* input_ptr, std::size_t input_len);
const char* zfish_uci_format_score(std::uint8_t kind, int value, int extra);
int         zfish_uci_to_cp(int value, int material);
const char* zfish_uci_wdl(int value, int material);
const char* zfish_uci_format_square(std::uint8_t file, std::uint8_t rank);
const char* zfish_uci_format_move(std::uint8_t from_file,
                                  std::uint8_t from_rank,
                                  std::uint8_t to_file,
                                  std::uint8_t to_rank,
                                  std::uint8_t promotion);
const char* zfish_uci_to_lower(const unsigned char* input_ptr, std::size_t input_len);
const char* zfish_uci_format_info_no_moves(int                  depth,
                                           const unsigned char* score_ptr,
                                           std::size_t          score_len);
const char* zfish_uci_format_info_full(int                  depth,
                                       int                  sel_depth,
                                       std::size_t          multi_pv,
                                       const unsigned char* score_ptr,
                                       std::size_t          score_len,
                                       const unsigned char* bound_ptr,
                                       std::size_t          bound_len,
                                       const unsigned char* wdl_ptr,
                                       std::size_t          wdl_len,
                                       std::uint8_t         show_wdl,
                                       std::size_t          nodes,
                                       std::size_t          nps,
                                       int                  hashfull,
                                       std::size_t          tb_hits,
                                       std::size_t          time_ms,
                                       const unsigned char* pv_ptr,
                                       std::size_t          pv_len);
const char* zfish_uci_format_info_iter(int                  depth,
                                       const unsigned char* currmove_ptr,
                                       std::size_t          currmove_len,
                                       int                  currmove_number);
const char* zfish_uci_format_bestmove(const unsigned char* bestmove_ptr,
                                      std::size_t          bestmove_len,
                                      const unsigned char* ponder_ptr,
                                      std::size_t          ponder_len);
const char* zfish_uci_format_critical_error(const unsigned char* command_ptr,
                                            std::size_t          command_len,
                                            const unsigned char* message_ptr,
                                            std::size_t          message_len);
}
#endif

namespace Stockfish {

class Position;
class Move;
enum Square : uint8_t;
using Value = int;

constexpr auto StartFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

class UCIEngine {
   public:
    UCIEngine(int argc, char** argv);

    void loop();

    static int         to_cp(Value v, const Position& pos);
    static std::string format_score(const Score& s);
    static std::string square(Square s);
    static std::string move(Move m, bool chess960 = false);
    static std::string wdl(Value v, const Position& pos);
    static std::string to_lower(std::string str);
    static std::string help_text();
    static std::string format_unknown_command(std::string_view command);
    static Move        to_move(const Position& pos, std::string str);

    static Search::LimitsType parse_limits(std::istream& is);

    auto& engine_options() { return engine.get_options(); }

   private:
    Engine      engine;
    CommandLine cli;

    static void print_info_string(std::string_view str);

    void          go(std::istringstream& is);
    void          bench(std::istream& args);
    void          benchmark(std::istream& args);
    void          position(std::istringstream& is);
    void          setoption(std::istringstream& is);
    std::uint64_t perft(const Search::LimitsType&);

    static void on_update_no_moves(const Engine::InfoShort& info);
    static void on_update_full(const Engine::InfoFull& info, bool showWDL);
    static void on_iter(const Engine::InfoIter& info);
    static void on_bestmove(std::string_view bestmove, std::string_view ponder);

    void init_search_update_listeners();

    [[noreturn]] void terminate_on_critical_error(const std::string& fullCommand,
                                                  const std::string& message);
};

#if defined(ZFISH_ZIG_BUILD)
inline std::string take_zig_uci_string_and_free(const char* rendered) {
    if (!rendered)
        return {};

    std::string value(rendered);
    std::free(const_cast<char*>(rendered));
    return value;
}

inline int zig_uci_material_count(const Position& pos) {
    return pos.count<PAWN>() + 3 * pos.count<KNIGHT>() + 3 * pos.count<BISHOP>()
         + 5 * pos.count<ROOK>() + 9 * pos.count<QUEEN>();
}

inline void UCIEngine::print_info_string(std::string_view str) {
    const auto rendered = take_zig_uci_string_and_free(
      zfish_uci_format_info_string(reinterpret_cast<const unsigned char*>(str.data()), str.size()));
    if (rendered.empty())
        return;

    sync_cout_start();
    std::cout << rendered << '\n';
    sync_cout_end();
}

inline std::string UCIEngine::format_score(const Score& s) {
    if (s.is<Score::Mate>())
    {
        const auto mate = s.get<Score::Mate>();
        return take_zig_uci_string_and_free(zfish_uci_format_score(0, mate.plies, 0));
    }

    if (s.is<Score::Tablebase>())
    {
        const auto tb = s.get<Score::Tablebase>();
        return take_zig_uci_string_and_free(zfish_uci_format_score(1, tb.plies, tb.win ? 1 : 0));
    }

    const auto units = s.get<Score::InternalUnits>();
    return take_zig_uci_string_and_free(zfish_uci_format_score(2, units.value, 0));
}

inline int UCIEngine::to_cp(Value v, const Position& pos) {
    return zfish_uci_to_cp(v, zig_uci_material_count(pos));
}

inline std::string UCIEngine::wdl(Value v, const Position& pos) {
    return take_zig_uci_string_and_free(zfish_uci_wdl(v, zig_uci_material_count(pos)));
}

inline std::string UCIEngine::square(Square s) {
    return take_zig_uci_string_and_free(
      zfish_uci_format_square(static_cast<std::uint8_t>(file_of(s)), static_cast<std::uint8_t>(rank_of(s))));
}

inline std::string UCIEngine::move(Move m, bool chess960) {
    if (m == Move::none())
        return "(none)";

    if (m == Move::null())
        return "0000";

    Square from = m.from_sq();
    Square to   = m.to_sq();

    if (m.type_of() == CASTLING && !chess960)
        to = make_square(to > from ? FILE_G : FILE_C, rank_of(from));

    const auto promotion =
      m.type_of() == PROMOTION ? static_cast<std::uint8_t>(" pnbrqk"[m.promotion_type()]) : 0;

    return take_zig_uci_string_and_free(zfish_uci_format_move(
      static_cast<std::uint8_t>(file_of(from)), static_cast<std::uint8_t>(rank_of(from)),
      static_cast<std::uint8_t>(file_of(to)), static_cast<std::uint8_t>(rank_of(to)), promotion));
}

inline std::string UCIEngine::to_lower(std::string str) {
    return take_zig_uci_string_and_free(
      zfish_uci_to_lower(reinterpret_cast<const unsigned char*>(str.data()), str.size()));
}

inline std::string UCIEngine::help_text() {
    return take_zig_uci_string_and_free(zfish_uci_help_text());
}

inline std::string UCIEngine::format_unknown_command(std::string_view command) {
    return take_zig_uci_string_and_free(
      zfish_uci_format_unknown_command(reinterpret_cast<const unsigned char*>(command.data()), command.size()));
}

inline Search::LimitsType UCIEngine::parse_limits(std::istream& is) {
    Search::LimitsType limits;
    limits.startTime = now();

    std::string rest;
    std::getline(is, rest);
    const auto parsed = zfish_uci_parse_limits(reinterpret_cast<const unsigned char*>(rest.data()),
                                               rest.size());

    limits.time[WHITE]   = parsed.wtime;
    limits.time[BLACK]   = parsed.btime;
    limits.inc[WHITE]    = parsed.winc;
    limits.inc[BLACK]    = parsed.binc;
    limits.movestogo     = parsed.movestogo;
    limits.depth         = parsed.depth;
    limits.nodes         = parsed.nodes;
    limits.movetime      = parsed.movetime;
    limits.mate          = parsed.mate;
    limits.perft         = parsed.perft;
    limits.infinite      = parsed.infinite;
    limits.ponderMode    = parsed.ponder_mode != 0;

    const auto searchmoves = take_zig_uci_string_and_free(parsed.searchmoves);
    for (const auto move : split(searchmoves, "\n"))
        limits.searchmoves.emplace_back(move);

    return limits;
}

inline void UCIEngine::position(std::istringstream& is) {
    const std::string fullCommand = is.str();
    const auto parsed = zfish_uci_parse_position(
      reinterpret_cast<const unsigned char*>(fullCommand.data()), fullCommand.size());
    if (!parsed.ok)
        return;

    const auto fen       = take_zig_uci_string_and_free(parsed.fen);
    const auto movesText = take_zig_uci_string_and_free(parsed.moves);

    std::vector<std::string> moves;
    for (const auto move : split(movesText, "\n"))
        moves.emplace_back(move);

    auto err = engine.set_position(fen, moves);
    if (err.has_value())
        terminate_on_critical_error(fullCommand, err->what());
}

inline void UCIEngine::on_update_no_moves(const Engine::InfoShort& info) {
    const auto score = format_score(info.score);
    sync_cout << take_zig_uci_string_and_free(zfish_uci_format_info_no_moves(
                   info.depth, reinterpret_cast<const unsigned char*>(score.data()), score.size()))
              << sync_endl;
}

inline void UCIEngine::on_update_full(const Engine::InfoFull& info, bool showWDL) {
    const auto score = format_score(info.score);
    sync_cout << take_zig_uci_string_and_free(zfish_uci_format_info_full(
                   info.depth, info.selDepth, info.multiPV,
                   reinterpret_cast<const unsigned char*>(score.data()), score.size(),
                   reinterpret_cast<const unsigned char*>(info.bound.data()), info.bound.size(),
                   reinterpret_cast<const unsigned char*>(info.wdl.data()), info.wdl.size(),
                   static_cast<std::uint8_t>(showWDL ? 1 : 0), info.nodes, info.nps, info.hashfull,
                   info.tbHits, info.timeMs, reinterpret_cast<const unsigned char*>(info.pv.data()),
                   info.pv.size()))
              << sync_endl;
}

inline void UCIEngine::on_iter(const Engine::InfoIter& info) {
    sync_cout
      << take_zig_uci_string_and_free(zfish_uci_format_info_iter(
           info.depth, reinterpret_cast<const unsigned char*>(info.currmove.data()),
           info.currmove.size(), info.currmovenumber))
      << sync_endl;
}

inline void UCIEngine::on_bestmove(std::string_view bestmove, std::string_view ponder) {
    sync_cout << take_zig_uci_string_and_free(zfish_uci_format_bestmove(
                   reinterpret_cast<const unsigned char*>(bestmove.data()), bestmove.size(),
                   reinterpret_cast<const unsigned char*>(ponder.data()), ponder.size()))
              << sync_endl;
}

inline void UCIEngine::terminate_on_critical_error(const std::string& fullCommand,
                                                   const std::string& message) {
    sync_cout << take_zig_uci_string_and_free(zfish_uci_format_critical_error(
                   reinterpret_cast<const unsigned char*>(fullCommand.data()), fullCommand.size(),
                   reinterpret_cast<const unsigned char*>(message.data()), message.size()))
              << sync_endl;
    std::exit(1);
}
#endif

}  // namespace Stockfish

#endif  // #ifndef UCI_H_INCLUDED
