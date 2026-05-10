//
//  FileHelpers.h
//  file-helpers
//
//  Header-only utilities for file path resolution.
//  Handles symlinks correctly for both existing and non-existing paths.
//

#ifndef FileHelpers_h
#define FileHelpers_h

#include <string>
#include <vector>
#include <cstring>
#include <climits>
#include <unistd.h>

#include "GlobOverlap.h"

namespace file_helpers
{

// Resolve a literal path (no glob patterns).
// For existing files/directories, uses realpath() directly.
// For non-existing paths (future outputs), walks up the directory chain to
// the deepest existing ancestor, realpath-resolves it, then re-appends the
// non-existing tail. This way /tmp → /private/tmp is preserved even when
// several intermediate components don't exist yet (e.g. a build tree to be
// created), so the resulting path can be compared by string prefix against
// other resolved paths during sandbox dedup.
inline std::string resolve_literal_path(const std::string& path)
{
    if (path.empty())
        return path;

    char resolved[PATH_MAX];
    if (realpath(path.c_str(), resolved))
        return std::string(resolved);

    // Walk up: peel components off the tail until realpath succeeds on the
    // remaining prefix. Then stitch the unresolved tail back on.
    std::string head = path;
    std::string tail;
    while (true)
    {
        size_t last_slash = head.rfind('/');
        if (last_slash == std::string::npos)
        {
            // No '/' left — head is a bare name. Try CWD as the anchor.
            char cwd[PATH_MAX];
            if (getcwd(cwd, sizeof(cwd)))
            {
                std::string out(cwd);
                out += '/';
                out += head;
                if (!tail.empty()) { out += '/'; out += tail; }
                return out;
            }
            break;
        }
        // Move one component from head to the front of tail.
        std::string comp = head.substr(last_slash + 1);
        head = head.substr(0, last_slash);
        if (!tail.empty()) tail = comp + "/" + tail;
        else tail = comp;

        // head may now be empty (we peeled the only component off "/leaf").
        // Treat empty head as "/" — root always exists and is its own realpath.
        const char* probe = head.empty() ? "/" : head.c_str();
        if (realpath(probe, resolved))
        {
            std::string out(resolved);
            if (out.empty() || out.back() != '/') out += '/';
            out += tail;
            return out;
        }
    }

    // Truly unresolvable — return the original path.
    return path;
}

// Split a path into components
inline std::vector<std::string> split_path_components(const std::string& path)
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
// Plain literal paths use resolve_literal_path() which properly handles
// symlinks for both existing and non-existing paths.
//
// Glob patterns are split on '/': the literal directory prefix (everything
// up to the first component containing a glob metacharacter) is resolved,
// and the glob suffix is appended verbatim.
//
// Patterns without any '/' (e.g. "*.gen.h") are gitignore-style basename
// shortcuts and are returned unchanged.
inline std::string resolve_path(const std::string& path)
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

}  // namespace file_helpers

#endif /* FileHelpers_h */
