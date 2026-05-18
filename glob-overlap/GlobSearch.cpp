#include "GlobSearch.h"
#include <algorithm>
#include <cassert>
#include <cstring>
#include <filesystem>
#include <fts.h>
#include <iostream>
#include <memory>

using FTSPtr = std::unique_ptr<FTS, decltype(&fts_close)>;

std::vector<Glob> compile_globs(const std::unordered_set<std::string>& glob_patterns) noexcept
{
    std::vector<Glob> compiled;
    if (glob_patterns.empty() || glob_patterns.count(""))
        return compiled;

    compiled.reserve(glob_patterns.size());
    for (const auto& pattern : glob_patterns)
    {
        int flags = FNM_CASEFOLD;
        if (pattern.find('/') != std::string::npos || pattern.find("**") != std::string::npos)
            flags |= FNM_PATHNAME;

        // glob-cpp does not honor FNM_CASEFOLD; lowercase the pattern so it
        // matches the lowercased haystack used by matches_any_glob().
        std::string folded(pattern);
        std::transform(folded.begin(), folded.end(), folded.begin(), ::tolower);
        compiled.emplace_back(folded, flags);
    }
    return compiled;
}

bool matches_any_glob(const char* relative_path, const std::vector<Glob>& patterns) noexcept
{
    assert(relative_path != nullptr && relative_path[0] != '\0');
    assert(relative_path[strlen(relative_path) - 1] != '/');

    std::string lowercase(relative_path);
    std::transform(lowercase.begin(), lowercase.end(), lowercase.begin(), ::tolower);
    const char* path = lowercase.c_str();

    const char* basename = std::strrchr(path, '/');
    basename = (basename != nullptr) ? basename + 1 : path;

    for (const auto& g : patterns)
    {
        const char* str = (g.flags & FNM_PATHNAME) ? path : basename;
        if (glob::glob_match(str, g.glob))
            return true;
    }
    return false;
}

static inline bool path_under_prefix(const char* path, size_t path_len,
                                     const std::string& prefix) noexcept
{
    size_t plen = prefix.size();
    if (path_len < plen)
        return false;
    if (std::memcmp(path, prefix.data(), plen) != 0)
        return false;
    if (path_len == plen)
        return true;
    return path[plen] == '/';
}

bool is_path_under_literal_exclude(const char* abs_path, size_t abs_len,
                                   const CompiledExcludes& excludes,
                                   const char* search_dir,
                                   size_t search_dir_len) noexcept
{
    for (const auto& lit : excludes.literal_abs)
    {
        if (path_under_prefix(abs_path, abs_len, lit))
            return true;
    }
    if (!excludes.literal_rel.empty() && search_dir != nullptr
        && abs_len > search_dir_len
        && std::memcmp(abs_path, search_dir, search_dir_len) == 0)
    {
        const char* rel = abs_path + search_dir_len;
        if (*rel == '/')
            ++rel;
        size_t rel_len = std::strlen(rel);
        for (const auto& lit : excludes.literal_rel)
        {
            if (path_under_prefix(rel, rel_len, lit))
                return true;
        }
    }
    return false;
}

CompiledExcludes compile_excludes(const std::unordered_set<std::string>& exclude_patterns) noexcept
{
    CompiledExcludes ce;
    if (exclude_patterns.empty())
        return ce;

    std::unordered_set<std::string> path_glob_abs_set;
    std::unordered_set<std::string> path_glob_rel_set;
    std::unordered_set<std::string> basename_glob_set;

    for (const auto& p : exclude_patterns)
    {
        if (p.empty())
            continue;

        bool has_glob  = globoverlap::contains_glob_pattern_char(p);
        bool has_slash = (p.find('/') != std::string::npos);
        bool is_abs    = (p[0] == '/');

        if (has_glob && !has_slash)
        {
            basename_glob_set.insert(p);
        }
        else if (has_glob)
        {
            (is_abs ? path_glob_abs_set : path_glob_rel_set).insert(p);
        }
        else
        {
            std::string lit = p;
            if (is_abs)
                lit = std::filesystem::path(p).lexically_normal().string();
            while (lit.size() > 1 && lit.back() == '/') lit.pop_back();
            (is_abs ? ce.literal_abs : ce.literal_rel).push_back(std::move(lit));
        }
    }

    ce.path_globs_abs = compile_globs(path_glob_abs_set);
    ce.path_globs_rel = compile_globs(path_glob_rel_set);
    ce.basename_globs = compile_globs(basename_glob_set);
    return ce;
}

bool is_path_excluded(const char* abs_path, const CompiledExcludes& excludes,
                      const char* search_dir) noexcept
{
    if (excludes.empty())
        return false;

    size_t path_len = std::strlen(abs_path);
    if (path_len == 0)
        return false;

    size_t search_dir_len = (search_dir != nullptr) ? std::strlen(search_dir) : 0;

    if (is_path_under_literal_exclude(abs_path, path_len, excludes, search_dir, search_dir_len))
        return true;

    if (!excludes.path_globs_abs.empty()
        && matches_any_glob(abs_path, excludes.path_globs_abs))
        return true;

    if (!excludes.path_globs_rel.empty() && search_dir != nullptr
        && path_len > search_dir_len
        && std::memcmp(abs_path, search_dir, search_dir_len) == 0)
    {
        const char* rel_path = abs_path + search_dir_len;
        if (*rel_path == '/')
            ++rel_path;
        if (rel_path[0] != '\0' && matches_any_glob(rel_path, excludes.path_globs_rel))
            return true;
    }

    if (!excludes.basename_globs.empty())
    {
        const char* basename = std::strrchr(abs_path, '/');
        basename = (basename != nullptr) ? basename + 1 : abs_path;
        if (basename[0] != '\0' && matches_any_glob(basename, excludes.basename_globs))
            return true;
    }

    return false;
}

// ============================================================================
// Regex
// ============================================================================

std::vector<Regex> compile_regexes(const std::unordered_set<std::string>& regex_patterns) noexcept
{
    std::vector<Regex> compiled;
    compiled.reserve(regex_patterns.size());
    for (const auto& pat : regex_patterns)
    {
        try
        {
            compiled.emplace_back(Regex{ std::regex(pat, std::regex::ECMAScript | std::regex::icase) });
        }
        catch (const std::regex_error& e)
        {
            std::cerr << "Invalid regex pattern: " << pat << " (" << e.what() << ")\n";
        }
    }
    return compiled;
}

bool matches_any_regex(const std::string& path, const std::vector<Regex>& regexes) noexcept
{
    for (const auto& r : regexes)
        if (std::regex_search(path, r.re))
            return true;
    return false;
}

// ============================================================================
// Directory walk
// ============================================================================

int walk_directory(const std::string& search_dir,
                   const std::vector<Glob>& compiled_globs,
                   const std::vector<Regex>& compiled_regexes,
                   const CompiledExcludes& compiled_excl,
                   FileMatchedBlock on_match,
                   std::vector<std::string>* symlinks_out,
                   int fts_flags) noexcept
{
    if (is_path_excluded(search_dir.c_str(), compiled_excl, search_dir.c_str()))
        return 0;

    char* paths[2] = { const_cast<char*>(search_dir.c_str()), nullptr };
    FTSPtr fts(fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | fts_flags, nullptr), fts_close);
    if (fts == nullptr)
        return errno != 0 ? errno : EXIT_FAILURE;

    bool match_all = compiled_globs.empty() && compiled_regexes.empty();
    int result = 0;
    FTSENT* ent;

    while ((ent = fts_read(fts.get())) != nullptr)
    {
        switch (ent->fts_info)
        {
            case FTS_D:
                if ((!compiled_excl.literal_abs.empty() || !compiled_excl.literal_rel.empty())
                    && is_path_under_literal_exclude(ent->fts_path, ent->fts_pathlen,
                                                     compiled_excl,
                                                     search_dir.c_str(), search_dir.size()))
                {
                    fts_set(fts.get(), ent, FTS_SKIP);
                }
                break;

            case FTS_F:
            case FTS_SL:
            case FTS_SLNONE:
            {
                if (is_path_excluded(ent->fts_path, compiled_excl, search_dir.c_str()))
                    break;

                if (match_all)
                {
                    on_match(ent->fts_path, ent->fts_statp);
                    // No symlink chain collection in match-all: all entries already delivered.
                    break;
                }

                const char* rel = ent->fts_path + search_dir.size();
                if (*rel == '/')
                    ++rel;

                if (matches_any_glob(rel, compiled_globs)
                    || matches_any_regex(std::string(rel), compiled_regexes))
                {
                    on_match(ent->fts_path, ent->fts_statp);
                }

                // Collect symlinks so the caller can follow chains outside search_dir.
                if (symlinks_out != nullptr
                    && (ent->fts_info == FTS_SL || ent->fts_info == FTS_SLNONE))
                {
                    symlinks_out->push_back(ent->fts_path);
                }
                break;
            }

            case FTS_ERR:
            case FTS_DNR:
                std::cerr << "fts error on: " << ent->fts_path
                          << " errno=" << ent->fts_errno << '\n';
                result = ent->fts_errno != 0 ? ent->fts_errno : EXIT_FAILURE;
                break;

            default:
                break;
        }
    }

    return result;
}
