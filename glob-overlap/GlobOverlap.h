#ifndef GLOB_OVERLAP_H
#define GLOB_OVERLAP_H

//
// GlobOverlap.h
//
// Determines whether two glob patterns can match any common file path.
// Uses a two-level approach:
//   Level 1: Segment-level DP handles ** (globstar)
//   Level 2: Character-level NFA product construction for per-segment overlap
//
// Brace groups {a,b,c} are pre-expanded before NFA construction.
// Extended globs (*(…), +(…), etc.) trigger conservative fallback (assume overlap).
//
// See patterns_overlap.cpp for standalone test tool and test_overlap.sh for test suite.
//

#include "glob.h"
#include <iostream>
#include <queue>
#include <set>
#include <string>
#include <vector>

namespace globoverlap {

// ============================================================================
// Brace Expansion
// ============================================================================

inline std::vector<std::string> split_brace_alternatives(const std::string& s) {
    std::vector<std::string> result;
    std::string current;
    int depth = 0;
    for (char c : s) {
        if (c == '{') depth++;
        else if (c == '}') depth--;
        if (c == ',' && depth == 0) {
            result.push_back(current);
            current.clear();
        } else {
            current += c;
        }
    }
    result.push_back(current);
    return result;
}

inline std::vector<std::string> expand_braces(const std::string& pattern) {
    int depth = 0;
    ssize_t brace_start = -1;
    for (size_t i = 0; i < pattern.size(); i++) {
        if (pattern[i] == '{') {
            if (depth == 0) brace_start = (ssize_t)i;
            depth++;
        } else if (pattern[i] == '}') {
            depth--;
            if (depth == 0 && brace_start >= 0) {
                std::string prefix = pattern.substr(0, brace_start);
                std::string interior = pattern.substr(brace_start + 1, i - brace_start - 1);
                std::string suffix = pattern.substr(i + 1);
                auto alternatives = split_brace_alternatives(interior);
                std::vector<std::string> results;
                for (const auto& alt : alternatives) {
                    auto expanded = expand_braces(prefix + alt + suffix);
                    results.insert(results.end(), expanded.begin(), expanded.end());
                }
                return results;
            }
        }
    }
    return {pattern};
}

// ============================================================================
// Segment Splitting
// ============================================================================

inline std::vector<std::string> split_segments(const std::string& pattern) {
    std::vector<std::string> segments;
    std::string current;
    for (char c : pattern) {
        if (c == '/') {
            if (!current.empty()) {
                segments.push_back(current);
                current.clear();
            }
        } else {
            current += c;
        }
    }
    if (!current.empty())
        segments.push_back(current);
    return segments;
}

// ============================================================================
// Character-level NFA product construction
// ============================================================================

inline glob::Automata<char> build_segment_nfa(const std::string& segment) {
    glob::Lexer<char> lexer(segment);
    auto tokens = lexer.Scanner();
    glob::Parser<char> parser(std::move(tokens));
    auto ast = parser.GenAst();
    glob::Automata<char> nfa;
    glob::AstConsumer<char> consumer;
    consumer.GenAutomata(ast.get(), nfa);
    return nfa;
}

inline bool segment_nfas_overlap(glob::Automata<char>& nfa1, glob::Automata<char>& nfa2) {
    using ProductState = std::pair<size_t, size_t>;

    std::set<ProductState> visited;
    std::queue<ProductState> bfs;

    auto enqueue = [&](size_t s1, size_t s2) {
        ProductState p{s1, s2};
        if (visited.insert(p).second)
            bfs.push(p);
    };

    enqueue(0, 0);

    while (!bfs.empty()) {
        auto [s1, s2] = bfs.front();
        bfs.pop();

        if (s1 == nfa1.MatchState() && s2 == nfa2.MatchState())
            return true;

        if (s1 == nfa1.FailState() || s2 == nfa2.FailState())
            continue;

        bool s1_accept = (s1 == nfa1.MatchState());
        bool s2_accept = (s2 == nfa2.MatchState());

        glob::State<char>* st1_ptr = s1_accept ? nullptr : &nfa1.GetState(s1);
        glob::State<char>* st2_ptr = s2_accept ? nullptr : &nfa2.GetState(s2);

        // Conservative fallback for GROUP states (extended globs).
        // GROUP states consume variable-length substrings and embed sub-automata,
        // making single-char product construction unsound.
        if ((st1_ptr && st1_ptr->Type() == glob::StateType::GROUP) ||
            (st2_ptr && st2_ptr->Type() == glob::StateType::GROUP)) {
            std::cerr << "warning: extended glob group detected, "
                         "assuming overlap (conservative)\n";
            return true;
        }

        // Epsilon transitions (MULT only: next[1] is the epsilon exit)
        if (st1_ptr && st1_ptr->Type() == glob::StateType::MULT
            && st1_ptr->GetNextStates().size() > 1) {
            enqueue(st1_ptr->GetNextStates()[1], s2);
        }
        if (st2_ptr && st2_ptr->Type() == glob::StateType::MULT
            && st2_ptr->GetNextStates().size() > 1) {
            enqueue(s1, st2_ptr->GetNextStates()[1]);
        }

        // Consuming transitions: both must consume the same character
        if (s1_accept || s2_accept)
            continue;

        auto t1 = st1_ptr->Type();
        auto t2 = st2_ptr->Type();

        bool has_common = false;
        if (t1 == glob::StateType::QUESTION || t2 == glob::StateType::QUESTION) {
            has_common = true;
        } else if (t1 == glob::StateType::MULT || t2 == glob::StateType::MULT) {
            has_common = true;
        } else {
            for (int c = 1; c < 256; c++) {
                if (c == '/') continue;
                std::string probe(1, static_cast<char>(c));
                if (st1_ptr->Check(probe, 0) && st2_ptr->Check(probe, 0)) {
                    has_common = true;
                    break;
                }
            }
        }

        if (has_common) {
            enqueue(st1_ptr->GetNextStates()[0], st2_ptr->GetNextStates()[0]);
        }
    }

    return false;
}

inline bool segments_overlap(const std::string& seg1, const std::string& seg2) {
    auto nfa1 = build_segment_nfa(seg1);
    auto nfa2 = build_segment_nfa(seg2);
    return segment_nfas_overlap(nfa1, nfa2);
}

// ============================================================================
// Segment-level DP (handles **)
// ============================================================================

inline bool pattern_segments_overlap(const std::vector<std::string>& segsA,
                                     const std::vector<std::string>& segsB) {
    int m = (int)segsA.size();
    int n = (int)segsB.size();

    std::vector<std::vector<bool>> dp(m + 1, std::vector<bool>(n + 1, false));
    dp[0][0] = true;

    for (int i = 0; i <= m; i++) {
        for (int j = 0; j <= n; j++) {
            if (!dp[i][j]) continue;

            if (i < m && segsA[i] == "**")
                dp[i + 1][j] = true;

            if (j < n && segsB[j] == "**")
                dp[i][j + 1] = true;

            if (i < m && j < n) {
                bool a_gs = (segsA[i] == "**");
                bool b_gs = (segsB[j] == "**");

                if (!a_gs && !b_gs) {
                    if (segments_overlap(segsA[i], segsB[j]))
                        dp[i + 1][j + 1] = true;
                } else if (a_gs && !b_gs) {
                    dp[i][j + 1] = true;
                } else if (!a_gs && b_gs) {
                    dp[i + 1][j] = true;
                }
            }
        }
    }

    return dp[m][n];
}

// ============================================================================
// Top-level API
// ============================================================================

// Returns true if two glob patterns can match any common file path.
// Exact for standard glob features (*, ?, [...], {...}, **).
// Conservative (returns true) for extended globs.
inline bool patterns_overlap(const std::string& pat1, const std::string& pat2) {
    auto expansions1 = expand_braces(pat1);
    auto expansions2 = expand_braces(pat2);

    for (const auto& exp1 : expansions1) {
        for (const auto& exp2 : expansions2) {
            auto segs1 = split_segments(exp1);
            auto segs2 = split_segments(exp2);
            if (pattern_segments_overlap(segs1, segs2))
                return true;
        }
    }

    return false;
}

inline bool contains_glob_pattern_char(const std::string& path) {
    bool has_meta = false;
    for (char c : path) {
        if (c == '*' || c == '?' || c == '[' || c == '{') {
            has_meta = true;
            break;
        }
    }
    return has_meta;
}

// Returns true if a path string is a well-formed glob pattern.
// First checks for glob metacharacters (*, ?, [, {), then validates
// the pattern through glob-cpp's lexer and parser. Malformed patterns
// (e.g. unclosed brackets, bad escapes) are rejected and treated as
// literal paths rather than risking undefined behavior in the NFA.
inline bool is_glob_pattern(const std::string& path) {
    bool has_pattern_char = contains_glob_pattern_char(path);
    if (!has_pattern_char)
        return false;

    // Validate by running through the lexer and parser.
    // Brace expansion first (since braces are handled outside glob-cpp),
    // then each expanded alternative must parse cleanly.
    try {
        auto expansions = expand_braces(path);
        for (const auto& exp : expansions) {
            auto segments = split_segments(exp);
            for (const auto& seg : segments) {
                if (seg == "**")
                    continue;
                glob::Lexer<char> lexer(seg);
                auto tokens = lexer.Scanner();
                glob::Parser<char> parser(std::move(tokens));
                parser.GenAst(); // throws glob::Error on malformed input
            }
        }
    } catch (const std::exception& e) {
        std::cerr << "warning: malformed glob pattern '" << path
                  << "': " << e.what() << " (treating as literal path)\n";
        return false;
    }
    return true;
}

} // namespace globoverlap

#endif // GLOB_OVERLAP_H
