//
//  SandboxProfile.cpp
//
//  Implementation of the sandbox module declared in SandboxProfile.h.
//  Pure C++; uses Json wrappers instead of NSJSONSerialization.
//

#include "SandboxProfile.h"
#include "FileHelpers.h"
#include "yyjson.hpp"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/dyld.h>


// Private SPI: declared in <sandbox.h> as deprecated, but the
// _with_parameters variant is in libSystem's tbd stubs without a header.
// Weak-link so the linker resolves it from the SDK; if the symbol is ever
// removed at runtime, the address compares equal to nullptr.
extern "C" int sandbox_init_with_parameters(const char *profile,
                                            uint64_t flags,
                                            const char *const parameters[],
                                            char **errorbuf)
    __attribute__((weak_import));

// Documented (deprecated) companion to sandbox_init_*; releases the buffer
// the SPI allocated for *errorbuf. Weak-imported for symmetry with the init
// SPI above so we can fall back to free() on the unlikely chance it's gone.
extern "C" void sandbox_free_error(char *errorbuf) __attribute__((weak_import));


namespace sandbox
{

namespace
{

// SBPL string literals must escape backslashes and double quotes. Paths
// that contain either are unusual but possible; handle them properly so
// a crafted directory cannot inject SBPL syntax.
std::string EscapeSbplStringLiteral(const std::string& s)
{
    std::string out;
    out.reserve(s.size() + 2);
    for (char c : s)
    {
        if (c == '\\' || c == '"')
            out.push_back('\\');
        out.push_back(c);
    }
    return out;
}

// Check if path is covered by any directory in the list (exact match or subdir)
bool IsCoveredBy(const std::string& path, const std::vector<std::string>& dirs)
{
    for (const auto& d : dirs)
    {
        if (path == d || (path.size() > d.size() && path.compare(0, d.size(), d) == 0 && path[d.size()] == '/'))
            return true;
    }
    return false;
}

// Deduplicate paths: resolve symlinks and remove any path that is a subdirectory of another.
// Filesystem root "/" is rejected with a warning — granting subpath on root would
// unlock the entire filesystem, defeating the point of the sandbox.
std::vector<std::string> DeduplicatePaths(const std::vector<std::string>& paths)
{
    std::vector<std::string> resolved;
    resolved.reserve(paths.size());
    for (const auto& p : paths)
    {
        if (p.empty())
            continue;
        std::string r = file_helpers::resolve_literal_path(p);
        if (r == "/")
        {
            fprintf(stderr, "warning: sandbox path \"%s\" resolves to \"/\" and was dropped; "
                            "granting access to the filesystem root is not allowed\n", p.c_str());
            continue;
        }
        resolved.push_back(std::move(r));
    }

    std::sort(resolved.begin(), resolved.end());
    resolved.erase(std::unique(resolved.begin(), resolved.end()), resolved.end());

    std::vector<std::string> result;
    for (const auto& p : resolved)
    {
        if (p.empty())
            continue;
        bool covered = false;
        for (const auto& r : result)
        {
            if (p == r || (p.size() > r.size() && p.compare(0, r.size(), r) == 0 && p[r.size()] == '/'))
            {
                covered = true;
                break;
            }
        }
        if (!covered)
            result.push_back(p);
    }
    return result;
}

// Add allow-read entries for paths that every sandboxed process needs at
// startup: LaunchServices quarantine-resolver prefs (otherwise the kernel
// violation rate-limiter fills up before action-level denials are logged)
// and the binary's own directory (codesign / quarantine checks).
//
// The binary-directory rule covers replay/gate as installed standalone
// (e.g. /usr/local/bin/replay or ~/.local/bin/replay): adding the parent
// dir is enough for codesign to verify the executable. If this code is
// ever linked into a bundled .app, the framework root or bundle root may
// also need to be added so dyld can load adjacent resources — revisit then.
void AddSystemAutoAllows(Config& cfg)
{
    const char *home = getenv("HOME");
    if (home != nullptr && home[0] != '\0')
        cfg.read_only.push_back(std::string(home) +
            "/Library/Preferences/com.apple.LaunchServices");

    char raw_path[PATH_MAX];
    uint32_t path_size = sizeof(raw_path);
    if (_NSGetExecutablePath(raw_path, &path_size) == 0)
    {
        char resolved[PATH_MAX];
        const char *canon = (realpath(raw_path, resolved) != nullptr)
                            ? resolved : raw_path;
        std::string exe(canon);
        auto slash = exe.rfind('/');
        if (slash != std::string::npos)
            cfg.read_only.push_back(exe.substr(0, slash));
    }
}

// Read a bool field from a JSON object node, with a default value.
// Accepts JSON bool only — numeric 0/1 would be ambiguous.
bool ReadBool(Json::Val obj, std::string_view key,
              bool default_value, bool& out,
              const std::string& path_for_errors)
{
    Json::Val v = obj.obj_get(key);
    if (!v.valid())
    {
        out = default_value;
        return true;
    }
    auto b = v.get_bool();
    if (!b.has_value())
    {
        fprintf(stderr, "error: sandbox profile %s: \"%.*s\" must be a boolean\n",
                path_for_errors.c_str(), (int)key.size(), key.data());
        return false;
    }
    out = *b;
    return true;
}

// Pull a string-array field from a JSON object node into a std::vector.
// Any non-string element is rejected with a diagnostic.
bool ReadStringArray(Json::Val obj, std::string_view key,
                     std::vector<std::string>& out,
                     const std::string& path_for_errors)
{
    Json::Val v = obj.obj_get(key);
    if (!v.valid())
        return true;  // optional field
    if (!v.is_arr())
    {
        fprintf(stderr, "error: sandbox profile %s: \"%.*s\" must be an array of strings\n",
                path_for_errors.c_str(), (int)key.size(), key.data());
        return false;
    }
    size_t n = v.arr_size();
    for (size_t i = 0; i < n; ++i)
    {
        auto s = v.arr_get(i).get_str();
        if (!s.has_value())
        {
            fprintf(stderr, "error: sandbox profile %s: \"%.*s\" contains non-string element\n",
                    path_for_errors.c_str(), (int)key.size(), key.data());
            return false;
        }
        out.emplace_back(*s);
    }
    return true;
}

}  // namespace


bool LoadConfigFromJsonFile(const std::string& path, Config& out)
{
    yyjson_read_err err{};
    Json::Document doc = Json::parse_file(path.c_str(), YYJSON_READ_NOFLAG, &err);
    if (!doc.valid())
    {
        fprintf(stderr, "error: cannot parse sandbox profile \"%s\": %s\n",
                path.c_str(), err.msg != nullptr ? err.msg : "unknown error");
        return false;
    }

    Json::Val root = doc.root();
    if (!root.is_obj())
    {
        fprintf(stderr, "error: sandbox profile \"%s\" root must be a JSON object\n",
                path.c_str());
        return false;
    }

    Config cfg;  // build into a temporary so partial failures don't pollute `out`

    if (!ReadBool(root, "import_baseline", true,  cfg.import_baseline, path)) return false;
    if (!ReadBool(root, "allow_network",   true,  cfg.allow_network,   path)) return false;
    if (!ReadBool(root, "allow_exec",      true,  cfg.allow_exec,      path)) return false;
    if (!ReadBool(root, "allow_fork",      true,  cfg.allow_fork,      path)) return false;

    if (!ReadStringArray(root, "read_only",   cfg.read_only,   path)) return false;
    if (!ReadStringArray(root, "read_write",  cfg.read_write,  path)) return false;
    if (!ReadStringArray(root, "extra_rules", cfg.extra_rules, path)) return false;

    // Move into out so callers can pre-populate fields before calling — we
    // overwrite with parsed values and the caller can then append more.
    out = std::move(cfg);
    return true;
}


std::string GenerateSbplProfile(const Config& config)
{
    std::string p;
    p.reserve(512);

    p += "(version 1)\n";
    p += "(debug deny)\n";

    if (config.import_baseline)
        p += "(import \"bsd.sb\")\n";

    p += "\n";

    p += "(allow user-preference-read)\n";

    if (config.allow_exec)
        p += "(allow process-exec*)\n";
    if (config.allow_fork)
        p += "(allow process-fork)\n";

    // Allow signaling processes inside this sandbox. Without this, kill()
    // against a posix_spawned child fails with EPERM and a timeout-driven
    // termination cannot actually kill the runaway child: Run() returns in
    // bounded time (good) but the child is leaked, surviving its parent
    // until its natural exit (bad).
    p += "(allow signal (target same-sandbox))\n";

    // Deduplicate read_write paths (covers read access implicitly)
    std::vector<std::string> rw_dirs = DeduplicatePaths(config.read_write);

    // For read_only: filter out paths covered by read_write, then deduplicate
    std::vector<std::string> ro_dirs;
    for (const auto& dir : config.read_only)
    {
        std::string resolved_dir = file_helpers::resolve_literal_path(dir);
        if (!IsCoveredBy(resolved_dir, rw_dirs))
            ro_dirs.push_back(resolved_dir);
    }
    std::vector<std::string> ro_filtered = DeduplicatePaths(ro_dirs);

    if (!ro_filtered.empty())
    {
        p += "\n; read-only allowed dirs\n";
        for (const auto& dir : ro_filtered)
        {
            p += "(allow file-read* (subpath \"";
            p += EscapeSbplStringLiteral(dir);
            p += "\"))\n";
        }
    }

    if (!rw_dirs.empty())
    {
        p += "\n; read-write allowed dirs\n";
        for (const auto& dir : rw_dirs)
        {
            p += "(allow file-read* file-write* (subpath \"";
            p += EscapeSbplStringLiteral(dir);
            p += "\"))\n";
        }
    }

    // Always emit an explicit network rule so our intent overrides whatever
    // bsd.sb's baseline permits on the current OS version.
    if (config.allow_network)
        p += "\n(allow network*)\n";
    else
        p += "\n(deny network*)\n";

    if (!config.extra_rules.empty())
    {
        p += "\n; extra rules\n";
        for (const auto& rule : config.extra_rules)
        {
            p += rule;
            p += "\n";
        }
    }

    return p;
}


bool IsAvailable()
{
    return (&sandbox_init_with_parameters != nullptr);
}


bool ApplyProfile(const std::string& sbpl_profile, bool verbose)
{
    if (!IsAvailable())
    {
        fprintf(stderr, "error: sandbox_init_with_parameters is not available on this system\n");
        return false;
    }

    if (verbose)
    {
        fprintf(stdout, "Sandbox profile:\n%s\n", sbpl_profile.c_str());
    }

    char *errbuf = nullptr;
    int rc = sandbox_init_with_parameters(sbpl_profile.c_str(), 0, nullptr, &errbuf);
    if (rc != 0)
    {
        fprintf(stderr, "error: failed to apply sandbox profile: %s\n",
                (errbuf != nullptr) ? errbuf : "unknown error");
        if (errbuf != nullptr)
        {
            if (&sandbox_free_error != nullptr)
                sandbox_free_error(errbuf);
            else
                free(errbuf);
        }
        return false;
    }
    return true;
}


bool ApplyConfig(const Config& config, bool verbose)
{
    std::string profile = GenerateSbplProfile(config);
    return ApplyProfile(profile, verbose);
}


bool InitializeSandbox(const std::string& profile_path,
                  const std::vector<std::string>& allow_read,
                  const std::vector<std::string>& allow_write,
                  bool allow_network,
                  bool verbose)
{
    Config cfg;
    if (!profile_path.empty())
    {
        if (!LoadConfigFromJsonFile(profile_path, cfg))
            return false;
    }
    for (const auto& p : allow_read)
        cfg.read_only.push_back(p);
    for (const auto& p : allow_write)
        cfg.read_write.push_back(p);
    cfg.allow_network = allow_network;
    AddSystemAutoAllows(cfg);
    return ApplyConfig(cfg, verbose);
}

}  // namespace sandbox
