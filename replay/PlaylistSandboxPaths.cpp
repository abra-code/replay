//
//  PlaylistSandboxPaths.cpp
//
//  Phase 5b: rewritten in pure C++ using ActionStep accessors.
//  The playlist is now loaded once in main() and passed here as a flat
//  vector of ActionStep objects — no second file read.
//

#include "PlaylistSandboxPaths.h"
#include "FileHelpers.h"
#include "FileSystemHelpers.h"
#include "GlobOverlap.h"
#include "PosixFileOps.h"
#include "EnvVarExpand.h"

#include <string>
#include <unordered_map>
#include <vector>


// Add one concrete or glob path to the appropriate sandbox vector.
// is_write=true  -> parent directory is added to writes (creation/deletion needs rw on parent).
//                  Skips parent == "/" to avoid granting full write access.
// is_write=false -> the path itself is added to reads.
// Glob patterns -> concrete prefix dir before first metachar; endnode-only globs are skipped.
static void AddPathToSandbox(const std::string& rawPath,
                               const std::unordered_map<std::string, std::string>& env,
                               bool is_write,
                               std::vector<std::string>& reads,
                               std::vector<std::string>& writes)
{
    auto expanded = expand_env_vars(rawPath.c_str(), env);
    if (!expanded.has_value() || expanded->empty())
        return;

    std::string p = file_helpers::resolve_literal_path(*expanded);
    if (p.empty())
        return;

    if (globoverlap::is_glob_pattern(p))
    {
        std::string prefix = globoverlap::glob_concrete_prefix(p);
        if (prefix.empty())
            return;
        if (is_write)
            writes.push_back(prefix);
        else
            reads.push_back(prefix);
        return;
    }

    if (is_write)
    {
        std::string parent = posix_parent_dir(p);
        if (parent.size() > 1)
            writes.push_back(parent);
    }
    else
    {
        reads.push_back(p);
    }
}

// Add all paths under a given key from an ActionStep to the sandbox vectors.
// The key may hold a single string or an array of strings.
static void AddFieldToSandbox(const ActionStep& action, std::string_view key,
                                const std::unordered_map<std::string, std::string>& env,
                                bool is_write,
                                std::vector<std::string>& reads,
                                std::vector<std::string>& writes)
{
    auto sval = action.string_value(key);
    if (sval.has_value()) {
        AddPathToSandbox(*sval, env, is_write, reads, writes);
        return;
    }
    auto arrval = action.string_array(key);
    if (arrval.has_value()) {
        for (const auto& item : *arrval)
            AddPathToSandbox(item, env, is_write, reads, writes);
    }
}

static void ExtractPathsFromAction(const ActionStep& action,
                                    const std::unordered_map<std::string, std::string>& env,
                                    std::vector<std::string>& reads,
                                    std::vector<std::string>& writes)
{
    auto typeOpt = action.string_value("action");
    if (!typeOpt.has_value())
        return;

    const std::string& t = *typeOpt;

    if (t == "read")
    {
        AddFieldToSandbox(action, "items", env, false, reads, writes);
    }
    else if (t == "info")
    {
        AddFieldToSandbox(action, "path",  env, false, reads, writes);
        AddFieldToSandbox(action, "items", env, false, reads, writes);
    }
    else if (t == "list" || t == "tree")
    {
        AddFieldToSandbox(action, "directory", env, false, reads, writes);
    }
    else if (t == "glob")
    {
        AddFieldToSandbox(action, "root", env, false, reads, writes);
    }
    else if (t == "create")
    {
        AddFieldToSandbox(action, "file",      env, true, reads, writes);
        AddFieldToSandbox(action, "directory", env, true, reads, writes);
    }
    else if (t == "edit")
    {
        AddFieldToSandbox(action, "items", env, true, reads, writes);
    }
    else if (t == "clone"    || t == "copy" ||
             t == "hardlink" || t == "symlink")
    {
        AddFieldToSandbox(action, "from",                  env, false, reads, writes);
        AddFieldToSandbox(action, "items",                 env, false, reads, writes);
        AddFieldToSandbox(action, "to",                    env, true,  reads, writes);
        AddFieldToSandbox(action, "destination directory", env, true,  reads, writes);
    }
    else if (t == "move")
    {
        // sources are exclusive inputs — moved out of source location, so source needs rw
        AddFieldToSandbox(action, "from",                  env, true, reads, writes);
        AddFieldToSandbox(action, "items",                 env, true, reads, writes);
        AddFieldToSandbox(action, "to",                    env, true, reads, writes);
        AddFieldToSandbox(action, "destination directory", env, true, reads, writes);
    }
    else if (t == "delete")
    {
        AddFieldToSandbox(action, "items", env, true, reads, writes);
    }
    else if (t == "execute")
    {
        auto tool = action.string_value("tool");
        if (tool.has_value() && !tool->empty())
        {
            auto toolExpanded = expand_env_vars(tool->c_str(), env);
            if (toolExpanded.has_value() && !toolExpanded->empty())
            {
                std::string toolPath = file_helpers::resolve_literal_path(*toolExpanded);
                std::string toolParent = posix_parent_dir(toolPath);
                if (toolParent.size() > 1)
                    reads.push_back(toolParent);
            }
        }
        AddFieldToSandbox(action, "inputs",           env, false, reads, writes);
        AddFieldToSandbox(action, "exclusive inputs", env, true,  reads, writes);
        AddFieldToSandbox(action, "outputs",          env, true,  reads, writes);
    }
    // "echo" has no path-bearing fields.

    auto deps = action.step_value("dependencies");
    if (deps.has_value())
        AddFieldToSandbox(*deps, "mutatingInputs", env, true, reads, writes);
}


void ExtractPlaylistSandboxPaths(const std::vector<ActionStep>& steps,
                                  const std::unordered_map<std::string, std::string>& env,
                                  std::vector<std::string>& reads,
                                  std::vector<std::string>& writes)
{
    for (const auto& step : steps)
        ExtractPathsFromAction(step, env, reads, writes);
}
