#pragma once
#include "GlobOverlap.h"
#include <fnmatch.h>
#include <regex>
#include <string>
#include <vector>
#include <unordered_set>
#include <sys/stat.h>

// Compiled glob pattern — case-insensitive via lowercased pattern + lowercased haystack.
// Move-only (glob::glob is not copyable).
struct Glob
{
    explicit Glob(const std::string& pattern, int flags) noexcept
        : glob(pattern), flags(flags) {}

    mutable glob::glob glob;
    int                flags;  // FNM_PATHNAME: match full path; otherwise: basename only
};

// Compile patterns for repeated matching. Returns an empty vector for empty input,
// which callers interpret as "match all". Patterns are lowercased (case-insensitive
// matching via lowercased haystack). Patterns containing '/' or '**' get FNM_PATHNAME
// so they are matched against the full path rather than just the basename.
std::vector<Glob> compile_globs(const std::unordered_set<std::string>& patterns) noexcept;

// Returns true if any compiled glob in `patterns` matches `relative_path`.
// FNM_PATHNAME globs match the full path; others match only the basename.
// Matching is case-insensitive (haystack is lowercased internally).
bool matches_any_glob(const char* relative_path, const std::vector<Glob>& patterns) noexcept;

// ============================================================================
// Compiled regex patterns
// ============================================================================

struct Regex { std::regex re; };

// Compile ECMAScript case-insensitive regex patterns. Invalid patterns are
// logged to stderr and skipped.
std::vector<Regex> compile_regexes(const std::unordered_set<std::string>& patterns) noexcept;

// Returns true if any regex in `regexes` matches path via regex_search.
bool matches_any_regex(const std::string& path, const std::vector<Regex>& regexes) noexcept;

// ============================================================================
// Compiled exclusion filters
// ============================================================================

// Patterns partitioned by shape for efficient per-category matching:
//   literal_abs:    absolute literal paths  (e.g. "/proj/src/generated")
//   literal_rel:    relative literal paths  (e.g. "src/generated")
//   path_globs_abs: absolute glob patterns  (e.g. "/proj/src/**/*.gen.h")
//   path_globs_rel: relative glob patterns  (e.g. "src/**/*.gen.h")
//   basename_globs: no-slash glob patterns  (e.g. "*.gen.h")
struct CompiledExcludes
{
    std::vector<std::string> literal_abs;
    std::vector<std::string> literal_rel;
    std::vector<Glob>        path_globs_abs;
    std::vector<Glob>        path_globs_rel;
    std::vector<Glob>        basename_globs;

    bool empty() const noexcept
    {
        return literal_abs.empty() && literal_rel.empty()
            && path_globs_abs.empty() && path_globs_rel.empty()
            && basename_globs.empty();
    }
};

CompiledExcludes compile_excludes(const std::unordered_set<std::string>& exclude_patterns) noexcept;

// Returns true if abs_path (or a path relative to search_dir) matches any literal exclude.
// Used to prune entire directory subtrees before descending into them.
bool is_path_under_literal_exclude(const char* abs_path, size_t abs_len,
                                   const CompiledExcludes& excludes,
                                   const char* search_dir,
                                   size_t search_dir_len) noexcept;

// Returns true if abs_path is excluded by any rule in `excludes`.
// search_dir (optional): enables relative literal and relative path-glob matching.
// Pass nullptr to match only absolute patterns and basename globs.
// abs_path must not end with '/'.
bool is_path_excluded(const char* abs_path, const CompiledExcludes& excludes,
                      const char* search_dir = nullptr) noexcept;

// ============================================================================
// Directory walk with pattern-filtered callback
// ============================================================================

// GCD block called for each file that passes include/exclude filters.
typedef void (^FileMatchedBlock)(const char* abs_path, struct stat* statp);

// Walk search_dir with FTS, calling on_match for each non-excluded entry that
// matches compiled_globs or compiled_regexes. When both vectors are empty every
// non-excluded entry matches. Runs synchronously on the calling thread.
//
// symlinks_out: if non-null, appended with absolute paths of all non-excluded
//   FTS_SL/FTS_SLNONE entries (regardless of pattern match) so the caller can
//   follow symlink chains outside search_dir. Not populated in the match-all
//   case (empty globs and regexes) since all entries are already delivered to
//   on_match.
//
// fts_flags: extra flags ORed into FTS_PHYSICAL | FTS_NOCHDIR. Callers that
//   need to stay on one filesystem pass FTS_XDEV here.
//
// Returns 0 on success, errno on FTS open failure or traversal error.
int walk_directory(const std::string& search_dir,
                   const std::vector<Glob>& compiled_globs,
                   const std::vector<Regex>& compiled_regexes,
                   const CompiledExcludes& compiled_excl,
                   FileMatchedBlock on_match,
                   std::vector<std::string>* symlinks_out = nullptr,
                   int fts_flags = 0) noexcept;
