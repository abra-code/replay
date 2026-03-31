//
//  path_helpers.cpp
//  gate
//
//  Created by Tomasz Kukielka on 3/30/26.
//

#include "path_helpers.h"
#include <unistd.h>

// Resolve a path to absolute canonical form.
// For existing files, uses realpath() directly.
// For non-existing files (future outputs), resolves the parent directory
// and appends the filename, so symlinks in the directory are resolved.
std::string resolve_path(const std::string& path)
{
    char resolved[PATH_MAX];
    if (realpath(path.c_str(), resolved))
        return std::string(resolved);

    // File doesn't exist yet — resolve the parent directory
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

    if (path[0] == '/')
        return path;

    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof(cwd)))
        return std::string(cwd) + "/" + path;

    return path;
}
