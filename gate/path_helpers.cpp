//
//  path_helpers.cpp
//  gate
//
//  Created by Tomasz Kukielka on 3/30/26.
//

#include "path_helpers.h"
#include "globoverlap.h"
#include <unistd.h>
#include <string>
#include <vector>

static std::string resolve_literal_path(const std::string& path);

static std::vector<std::string> split_path_components(const std::string& path)
{
    std::vector<std::string> result;
    if (path.empty()) return result;
    size_t start = 0;
    if (path[0] == '/')
    {
        result.emplace_back("");
        start = 1;
    }
    size_t pos;
    while ((pos = path.find('/', start)) != std::string::npos)
    {
        if (pos > start) result.emplace_back(path.substr(start, pos - start));
        start = pos + 1;
    }
    if (start < path.length()) result.emplace_back(path.substr(start));
    return result;
}

// Resolve a path or glob pattern to absolute canonical form.
//
// Plain literal paths use realpath(); for not-yet-existing paths the parent
// directory is realpath-resolved and the leaf appended (preserves symlink
// resolution for future outputs).
//
// Glob patterns are split on '/': the literal directory prefix (everything
// up to the first component containing a glob metacharacter) is realpath-
// resolved, and the glob suffix is appended verbatim.
//
// Patterns without any '/' (e.g. "*.gen.h") are gitignore-style basename
// shortcuts and are returned unchanged.
std::string resolve_path(const std::string& path)
{
    if (!globoverlap::contains_glob_pattern_char(path))
        return resolve_literal_path(path);

    if (path.find('/') == std::string::npos)
        return path;  // basename-style pattern: preserved as-is

    auto components = split_path_components(path);
    bool is_absolute = !components.empty() && components[0].empty();
    size_t split_idx = is_absolute ? 1 : 0;
    while (split_idx < components.size()
           && !globoverlap::contains_glob_pattern_char(components[split_idx]))
        ++split_idx;

    std::string prefix;
    if (is_absolute)
    {
        prefix = "/";
        for (size_t i = 1; i < split_idx; ++i)
        {
            if (prefix.size() > 1) prefix += '/';
            prefix += components[i];
        }
    }
    else
    {
        for (size_t i = 0; i < split_idx; ++i)
        {
            if (!prefix.empty()) prefix += '/';
            prefix += components[i];
        }
    }
    if (prefix.empty()) prefix = is_absolute ? "/" : ".";

    std::string resolved_prefix = resolve_literal_path(prefix);

    if (split_idx == components.size())
        return resolved_prefix;

    std::string suffix;
    for (size_t i = split_idx; i < components.size(); ++i)
    {
        if (!suffix.empty()) suffix += '/';
        suffix += components[i];
    }

    if (!resolved_prefix.empty() && resolved_prefix.back() != '/')
        resolved_prefix += '/';
    return resolved_prefix + suffix;
}

// Resolve a path that contains no glob metacharacters.
// For existing files, uses realpath() directly.
// For non-existing files (future outputs), resolves the parent directory
// and appends the filename, so symlinks in the directory are resolved.
static std::string resolve_literal_path(const std::string& path)
{
    char resolved[PATH_MAX];
    if (realpath(path.c_str(), resolved))
        return std::string(resolved);

    std::string dir, base;
    size_t last_slash = path.rfind('/');
    if (last_slash != std::string::npos)
    {
        dir = path.substr(0, last_slash);
        base = path.substr(last_slash + 1);
    }
    else
    {
        dir = ".";
        base = path;
    }

    if (realpath(dir.c_str(), resolved))
        return std::string(resolved) + "/" + base;

    if (!path.empty() && path[0] == '/')
        return path;

    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof(cwd)))
        return std::string(cwd) + "/" + path;

    return path;
}
