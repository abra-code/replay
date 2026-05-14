//
//  MCPServer.mm
//  replay — MCP stdio server (JSON-RPC 2.0 / Model Context Protocol)
//
//  Thin dispatch layer: parses JSON-RPC requests, validates paths, and routes
//  each tools/call to the existing action infrastructure (ReadFileAction.mm,
//  DirActions.mm, EditAction.mm, etc.) via a GCD concurrent queue.
//  Action functions write responses through OutputSerializer using index=-1
//  (unordered FIFO). Protocol messages are handled inline and written directly.
//

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#include "MCPServer.h"
#include "FileSystemHelpers.h"
#include "GlobOverlap.h"
#include "ABase64.h"
#include "yyjson.hpp"

#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <cassert>

#include <string>
#include <string_view>
#include <vector>
#include <memory>
#include <mutex>
#include <fstream>
#include <iostream>

#include "AsyncDispatch.h"

#include <unistd.h>
#include <sys/stat.h>
#include <limits.h>

static constexpr const char *kProtocolVersion = "2024-11-05";
static constexpr const char *kServerName      = "replay-mcp";
static constexpr const char *kServerVersion   = "1.0.0";
static constexpr size_t kMaxFileSize          = 10u * 1024u * 1024u;
static constexpr size_t kMaxReadMultiple      = 50;
static constexpr int    kDefaultCommandTimeout = 30; // seconds; passed via ActionContext settings
static constexpr int    kMaxCommandTimeout     = 60; // seconds; hard cap enforced here


// ============================================================================
// ID — preserve the raw JSON of the request id (number / string / null)
// ============================================================================

static std::string extract_request_id(Json::Val id_val)
{
    if (!id_val.valid())
        return "null";
    yyjson_write_err err{};
    size_t len = 0;
    char *raw = yyjson_val_write_opts(id_val.raw(), 0, nullptr, &len, &err);
    if (raw == nullptr)
        return "null";
    std::string result(raw, len);
    free(raw);
    return result;
}

// ============================================================================
// Path validation
// ============================================================================

struct PathResult {
    bool ok = false;
    std::string canonical;
    std::string error;
};

static PathResult resolve_path(const std::string &requested)
{
    char buf[PATH_MAX];
    if (realpath(requested.c_str(), buf) != nullptr)
        return {true, std::string(buf), {}};

    // Non-existent path: walk up until we find an existing ancestor
    std::vector<std::string> suffix;
    std::string cur = requested;

    // Strip trailing slashes
    while (cur.size() > 1 && cur.back() == '/')
        cur.pop_back();

    while (true)
    {
        size_t slash = cur.rfind('/');
        if (slash == std::string::npos || slash == 0)
            break;
        suffix.push_back(cur.substr(slash + 1));
        cur = cur.substr(0, slash);
        if (realpath(cur.c_str(), buf) != nullptr)
        {
            std::string result(buf);
            for (int i = (int)suffix.size() - 1; i >= 0; i--)
            {
                result += '/';
                result += suffix[i];
            }
            return {true, result, {}};
        }
    }
    return {false, {}, "Cannot resolve path: " + requested};
}

static PathResult validate_path(const std::string &requested,
                                 const MCPServerOptions &opts,
                                 bool need_writable)
{
    auto r = resolve_path(requested);
    if (!r.ok)
        return r;

    for (const auto &dir : opts.allowedDirs)
    {
        if (need_writable && !dir.writable)
            continue;
        if (r.canonical == dir.path || r.canonical.starts_with(dir.path + "/"))
            return {true, r.canonical, {}};
    }
    return {false, {}, "Path not allowed: " + r.canonical};
}

// ============================================================================
// JSON-RPC response builders (private)
// ============================================================================

static std::string make_error_response(const std::string &request_id, int code,
                                        const std::string &msg)
{
    Json::MutableDoc doc;
    auto root = doc.new_obj();
    doc.obj_add(root, "jsonrpc", doc.new_str("2.0"));
    doc.obj_add(root, "id",      doc.new_raw(request_id));
    auto err = doc.new_obj();
    doc.obj_add(err, "code",    doc.new_sint(code));
    doc.obj_add(err, "message", doc.new_str(msg));
    doc.obj_add(root, "error", err);
    doc.set_root(root);
    std::string json = doc.to_string();
    json.push_back('\n');
    return json;
}

static std::string make_result_response(const std::string &request_id,
                                         Json::MutableDoc &doc,
                                         Json::MutableVal result)
{
    auto root = doc.new_obj();
    doc.obj_add(root, "jsonrpc", doc.new_str("2.0"));
    doc.obj_add(root, "id",      doc.new_raw(request_id));
    doc.obj_add(root, "result",  result);
    doc.set_root(root);
    std::string json = doc.to_string();
    json.push_back('\n');
    return json;
}

static std::string make_text_result(const std::string &request_id, std::string text)
{
    Json::MutableDoc doc;
    auto item = doc.new_obj();
    doc.obj_add(item, "type", doc.new_str("text"));
    doc.obj_add(item, "text", doc.new_str(text));
    auto content = doc.new_arr();
    doc.arr_append(content, item);
    auto result = doc.new_obj();
    doc.obj_add(result, "content", content);
    return make_result_response(request_id, doc, result);
}

static std::string make_multi_text_result(const std::string &request_id,
                                           const std::vector<std::string> &texts)
{
    Json::MutableDoc doc;
    auto content = doc.new_arr();
    for (const auto &text : texts)
    {
        auto item = doc.new_obj();
        doc.obj_add(item, "type", doc.new_str("text"));
        doc.obj_add(item, "text", doc.new_str(text));
        doc.arr_append(content, item);
    }
    auto result = doc.new_obj();
    doc.obj_add(result, "content", content);
    return make_result_response(request_id, doc, result);
}

// ============================================================================
// Public MCP result/error builders (declared in MCPServer.h)
// Called from PrintMCP* helpers in ReplayActionPrivate.h
// ============================================================================

std::string MakeMCPTextResult(const std::string &request_id, std::string text)
{
    return make_text_result(request_id, std::move(text));
}

std::string MakeMCPBlobResult(const std::string &request_id, std::string base64Data,
                               std::string mimeType)
{
    Json::MutableDoc doc;
    auto item = doc.new_obj();
    doc.obj_add(item, "type",     doc.new_str("blob"));
    doc.obj_add(item, "data",     doc.new_str(base64Data));
    doc.obj_add(item, "mimeType", doc.new_str(mimeType));
    auto content = doc.new_arr();
    doc.arr_append(content, item);
    auto result = doc.new_obj();
    doc.obj_add(result, "content", content);
    return make_result_response(request_id, doc, result);
}

std::string MakeMCPError(const std::string &request_id, int code, std::string message)
{
    return make_error_response(request_id, code, message);
}

std::string MakeMCPMultiTextResult(const std::string &request_id,
                                    const std::vector<std::string> &texts)
{
    return make_multi_text_result(request_id, texts);
}

// pre-composed reponse
static inline void PrintMCPResponse(ReplayContext *context, ActionContext *actionContext,
                                       std::string response)
{
    assert(context->mcpServer);
    context->outputSerializer->scheduleString(std::move(response), -1);
}

// ============================================================================
// File helpers (used only by read_multiple_files inline handler)
// ============================================================================

struct ReadFileResult {
    bool ok       = false;
    bool is_text  = false;
    std::vector<uint8_t> data;
    std::string error;
};

static bool is_utf8_text(const uint8_t *data, size_t len)
{
    for (size_t i = 0; i < len; )
    {
        uint8_t c = data[i];
        if (c == 0) return false;
        size_t seqLen;
        if      ((c & 0x80u) == 0x00u) seqLen = 1;
        else if ((c & 0xE0u) == 0xC0u) seqLen = 2;
        else if ((c & 0xF0u) == 0xE0u) seqLen = 3;
        else if ((c & 0xF8u) == 0xF0u) seqLen = 4;
        else return false;
        for (size_t j = 1; j < seqLen; j++)
        {
            if (i + j >= len || (data[i + j] & 0xC0u) != 0x80u) return false;
        }
        i += seqLen;
    }
    return true;
}

static ReadFileResult read_file_bytes(const std::string &path)
{
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f.is_open())
        return {false, false, {}, std::string("Cannot open file: ") + strerror(errno)};

    auto size = f.tellg();
    if (size > (std::streamoff)kMaxFileSize)
        return {false, false, {}, "File exceeds 10 MB limit"};

    f.seekg(0, std::ios::beg);
    std::vector<uint8_t> data(static_cast<size_t>(size));
    if (size > 0 && !f.read(reinterpret_cast<char *>(data.data()), size))
        return {false, false, {}, "Failed to read file"};

    bool text = is_utf8_text(data.data(), data.size());
    return {true, text, std::move(data), {}};
}

// ============================================================================
// Param helper — validate a path param and emit an MCP error on failure
// ============================================================================

static std::string validate_and_get(Json::Val args, const char *key,
                                     const MCPServerOptions &opts, bool need_writable,
                                     ActionContext *ac, ReplayContext *context)
{
    auto sv = args.obj_get(key).get_str();
    if (!sv)
    {
        PrintMCPError(context, ac, -32602, std::string("Missing required param: ") + key);
        return {};
    }
    auto vr = validate_path(std::string(*sv), opts, need_writable);
    if (!vr.ok)
    {
        PrintMCPError(context, ac, -32001, vr.error);
        return {};
    }
    return vr.canonical;
}

// ============================================================================
// execute_command response builder — declared in MCPServer.h, called via
// PrintMCPExecuteResult in ReplayActionPrivate.h from ExecuteEchoActions.mm.
// Separate from make_text_result because it carries isError and an optional
// stderr content item.
// ============================================================================

std::string MakeMCPExecuteResult(const std::string &request_id,
                                  const MCPExecuteResult &r)
{
    Json::MutableDoc doc;
    auto content = doc.new_arr();

    // Primary item: stdout (or timeout notice) with exit code footer.
    {
        auto item = doc.new_obj();
        doc.obj_add(item, "type", doc.new_str("text"));
        std::string text;
        if (r.timed_out)
        {
            text = "[command timed out]\n";
            if (!r.stdout_text.empty())
                text += r.stdout_text;
        }
        else
        {
            text = r.stdout_text.empty() ? "(no output)\n" : r.stdout_text;
            if (!text.empty() && text.back() != '\n')
                text += '\n';
        }
        text += "[exit code: " + std::to_string(r.exit_code) + "]";
        doc.obj_add(item, "text", doc.new_str(text));
        doc.arr_append(content, item);
    }

    // Second item: stderr, only when non-empty.
    if (!r.stderr_text.empty())
    {
        auto item = doc.new_obj();
        doc.obj_add(item, "type", doc.new_str("text"));
        doc.obj_add(item, "text", doc.new_str("[stderr]\n" + r.stderr_text));
        doc.arr_append(content, item);
    }

    auto result = doc.new_obj();
    doc.obj_add(result, "content", content);
    if (r.timed_out || r.exit_code != 0)
        doc.obj_add(result, "isError", doc.new_bool(true));
    return make_result_response(request_id, doc, result);
}

// ============================================================================
// Tool dispatcher — maps tool name to action function call
// ============================================================================

static void dispatch_mcp_tool(const std::string &tool,
                               Json::Val args,
                               ReplayContext *context,
                               ActionContext *ac,
                               const MCPServerOptions *opts)
{
    if (tool == "read_file")
    {
        auto path = validate_and_get(args, "path", *opts, false, ac, context);
        if (path.empty()) return;
        ReadFile(path.c_str(), context, ac);
    }
    else if (tool == "list_directory")
    {
        auto path = validate_and_get(args, "path", *opts, false, ac, context);
        if (path.empty()) return;
        ListDirectory(path.c_str(), context, ac);
    }
    else if (tool == "directory_tree")
    {
        auto path = validate_and_get(args, "path", *opts, false, ac, context);
        if (path.empty()) return;
        NSInteger depth = 10;
        if (auto dv = args.obj_get("depth").get_sint(); dv && *dv >= 0)
            depth = (NSInteger)*dv;
        else if (auto dv2 = args.obj_get("depth").get_uint(); dv2)
            depth = (NSInteger)*dv2;
        DirectoryTree(path.c_str(), depth, context, ac);
    }
    else if (tool == "get_file_info")
    {
        auto path = validate_and_get(args, "path", *opts, false, ac, context);
        if (path.empty()) return;
        GetFileInfo(path.c_str(), context, ac);
    }
    else if (tool == "write_file")
    {
        auto path = validate_and_get(args, "path", *opts, true, ac, context);
        if (path.empty()) return;
        auto content_sv = args.obj_get("content").get_str();
        if (!content_sv)
        {
            PrintMCPError(context, ac, -32602, "Missing required param: content");
            return;
        }
        NSURL *url = [NSURL fileURLWithPath:@(path.c_str())];
        NSString *content = [NSString stringWithUTF8String:std::string(*content_sv).c_str()];
        // Ensure parent directory exists
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtURL:[url URLByDeletingLastPathComponent]
     withIntermediateDirectories:YES attributes:nil error:nil];
        CreateFile(url, content, context, ac);
    }
    else if (tool == "create_directory")
    {
        auto path = validate_and_get(args, "path", *opts, true, ac, context);
        if (path.empty()) return;
        NSURL *url = [NSURL fileURLWithPath:@(path.c_str()) isDirectory:YES];
        CreateDirectory(url, context, ac);
    }
    else if (tool == "move_file")
    {
        auto src = validate_and_get(args, "source", *opts, true, ac, context);
        if (src.empty()) return;
        auto dst = validate_and_get(args, "destination", *opts, true, ac, context);
        if (dst.empty()) return;
        NSURL *srcURL = [NSURL fileURLWithPath:@(src.c_str())];
        NSURL *dstURL = [NSURL fileURLWithPath:@(dst.c_str())];
        // Ensure destination parent exists
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtURL:[dstURL URLByDeletingLastPathComponent]
     withIntermediateDirectories:YES attributes:nil error:nil];
        MoveItem(srcURL, dstURL, context, ac);
    }
    else if (tool == "delete_file")
    {
        auto path = validate_and_get(args, "path", *opts, true, ac, context);
        if (path.empty()) return;
        NSURL *url = [NSURL fileURLWithPath:@(path.c_str())];
        DeleteItem(url, context, ac);
    }
    else if (tool == "edit_file")
    {
        // path validation: need write unless dry-run
        bool action_dry_run = false;
        if (auto dv = args.obj_get("dryRun").get_bool(); dv) action_dry_run = *dv;

        auto path_sv = args.obj_get("path").get_str();
        if (!path_sv) { PrintMCPError(context, ac, -32602, "Missing required param: path"); return; }
        auto vr = validate_path(std::string(*path_sv), *opts, !action_dry_run);
        if (!vr.ok) { PrintMCPError(context, ac, -32001, vr.error); return; }

        auto edits_val = args.obj_get("edits");
        if (!edits_val.is_arr())
        {
            PrintMCPError(context, ac, -32602, "Missing required param: edits (array)");
            return;
        }

        NSMutableArray<NSDictionary *> *edits = [NSMutableArray array];
        Json::ArrIter it(edits_val);
        while (it.has_next())
        {
            auto ev = it.next();
            if (!ev.is_obj()) continue;
            auto old_sv = ev.obj_get("oldText").get_str();
            if (!old_sv) continue;

            NSMutableDictionary *edit = [NSMutableDictionary dictionary];
            edit[@"oldText"] = [NSString stringWithUTF8String:std::string(*old_sv).c_str()];
            if (auto ns = ev.obj_get("newText").get_str(); ns)
                edit[@"newText"] = [NSString stringWithUTF8String:std::string(*ns).c_str()];
            if (auto lv = ev.obj_get("limit").get_sint(); lv)
                edit[@"limit"] = @((NSInteger)*lv);
            else if (auto lv2 = ev.obj_get("limit").get_uint(); lv2)
                edit[@"limit"] = @((NSInteger)*lv2);
            if (auto rv = ev.obj_get("regex").get_bool(); rv)
                edit[@"regex"] = @((BOOL)*rv);
            if (auto cv = ev.obj_get("caseInsensitive").get_bool(); cv)
                edit[@"case-insensitive"] = @((BOOL)*cv);
            [edits addObject:edit];
        }

        EditFile(vr.canonical.c_str(), edits, action_dry_run, context, ac);
    }
    else if (tool == "edit_files")
    {
        bool action_dry_run = false;
        if (auto dv = args.obj_get("dryRun").get_bool(); dv) action_dry_run = *dv;

        auto paths_val = args.obj_get("paths");
        if (!paths_val.is_arr())
        {
            PrintMCPError(context, ac, -32602, "Missing required param: paths (array)");
            return;
        }
        auto edits_val = args.obj_get("edits");
        if (!edits_val.is_arr())
        {
            PrintMCPError(context, ac, -32602, "Missing required param: edits (array)");
            return;
        }

        // Build edits array (same structure as edit_file)
        NSMutableArray<NSDictionary *> *edits = [NSMutableArray array];
        {
            Json::ArrIter it(edits_val);
            while (it.has_next())
            {
                auto ev = it.next();
                if (!ev.is_obj()) continue;
                auto old_sv = ev.obj_get("oldText").get_str();
                if (!old_sv) continue;
                NSMutableDictionary *edit = [NSMutableDictionary dictionary];
                edit[@"oldText"] = [NSString stringWithUTF8String:std::string(*old_sv).c_str()];
                if (auto ns = ev.obj_get("newText").get_str(); ns)
                    edit[@"newText"] = [NSString stringWithUTF8String:std::string(*ns).c_str()];
                if (auto lv = ev.obj_get("limit").get_sint(); lv)
                    edit[@"limit"] = @((NSInteger)*lv);
                else if (auto lv2 = ev.obj_get("limit").get_uint(); lv2)
                    edit[@"limit"] = @((NSInteger)*lv2);
                if (auto rv = ev.obj_get("regex").get_bool(); rv)
                    edit[@"regex"] = @((BOOL)*rv);
                if (auto cv = ev.obj_get("caseInsensitive").get_bool(); cv)
                    edit[@"case-insensitive"] = @((BOOL)*cv);
                [edits addObject:edit];
            }
        }

        // Expand paths: each entry is a literal path or a glob pattern
        std::vector<std::string> concrete_paths;
        {
            bool early_error = false;
            Json::ArrIter it(paths_val);
            while (it.has_next() && !early_error)
            {
                auto pv = it.next();
                auto ps = pv.get_str();
                if (!ps) continue;
                std::string path_str(*ps);

                if (globoverlap::contains_glob_pattern_char(path_str))
                {
                    auto matches = expand_glob(path_str);
                    if (matches.empty())
                    {
                        PrintMCPError(context, ac, -32002,
                                      "Glob matched no files: " + path_str);
                        early_error = true;
                        break;
                    }
                    for (const auto &m : matches)
                    {
                        auto vr = validate_path(m, *opts, !action_dry_run);
                        if (!vr.ok)
                        {
                            PrintMCPError(context, ac, -32001, vr.error);
                            early_error = true;
                            break;
                        }
                        concrete_paths.push_back(vr.canonical);
                    }
                }
                else
                {
                    auto vr = validate_path(path_str, *opts, !action_dry_run);
                    if (!vr.ok)
                    {
                        PrintMCPError(context, ac, -32001, vr.error);
                        early_error = true;
                        break;
                    }
                    concrete_paths.push_back(vr.canonical);
                }
            }
            if (early_error) return;
        }

        if (concrete_paths.empty())
        {
            PrintMCPError(context, ac, -32602, "paths resolved to no files");
            return;
        }

        // Edit each file; collect per-file results into one multi-text response
        std::vector<std::string> results;
        for (const auto &path : concrete_paths)
        {
            auto r = EditFileMCPCore(path.c_str(), edits, action_dry_run);
            if (r.ok)
                results.push_back(r.message);
            else
                results.push_back(path + ": [error " + std::to_string(r.error_code) + "] " + r.message);
        }
        PrintMCPMultiTextResult(context, ac, results);
    }
    else if (tool == "execute_command")
    {
        auto cmd_sv = args.obj_get("command").get_str();
        if (!cmd_sv)
        {
            PrintMCPError(context, ac, -32602, "Missing required param: command");
            return;
        }
        std::string command(*cmd_sv);

        // Optional working directory — must resolve within an allowed dir.
        std::string working_dir;
        if (auto wd_sv = args.obj_get("workingDirectory").get_str(); wd_sv)
        {
            auto vr = validate_path(std::string(*wd_sv), *opts, false);
            if (!vr.ok)
            {
                PrintMCPError(context, ac, -32001, vr.error);
                return;
            }
            working_dir = vr.canonical;
        }
        else
        {
            // Default: first writable allowed dir, else first readable dir.
            for (const auto &d : opts->allowedDirs)
            {
                if (d.writable)
                {
                    working_dir = d.path;
                    break;
                }
            }
            if (working_dir.empty() && !opts->allowedDirs.empty())
                working_dir = opts->allowedDirs[0].path;
        }

        // Optional timeout, capped at kMaxCommandTimeout.
        int timeout_sec = kDefaultCommandTimeout;
        if (auto tv = args.obj_get("timeout").get_sint(); tv && *tv > 0)
            timeout_sec = (int)std::min((int64_t)kMaxCommandTimeout, *tv);
        else if (auto tv2 = args.obj_get("timeout").get_uint(); tv2)
            timeout_sec = (int)std::min((uint64_t)kMaxCommandTimeout, *tv2);

        // Pass execution parameters via ActionContext settings.
        // ExcecuteTool detects context->mcpServer and delegates to ExcecuteToolMCPCore.
        ac->settings = @{
            @"workingDirectory": @(working_dir.c_str()),
            @"timeout":          @(timeout_sec),
        };
        ExcecuteTool(@"/bin/sh", @[@"-c", @(command.c_str())], context, ac);
    }
    else if (tool == "search_files")
    {
        // Content search (grep-style). Accepts:
        //   path      — root directory, search all files recursively (standard MCP)
        //   paths     — array of absolute paths / glob patterns (extended, overrides path)
        //   pattern   — content pattern (required)
        //   excludePatterns — file glob exclusions (applied when using path root dir)
        //   regex, caseInsensitive, contextLines, maxResults

        auto pat_sv = args.obj_get("pattern").get_str();
        if (!pat_sv)
        {
            PrintMCPError(context, ac, -32602, "Missing required param: pattern");
            return;
        }
        std::string pattern(*pat_sv);

        bool use_regex = false;
        if (auto v = args.obj_get("regex").get_bool(); v) use_regex = *v;
        bool case_insensitive = false;
        if (auto v = args.obj_get("caseInsensitive").get_bool(); v) case_insensitive = *v;

        int context_lines = 0;
        if (auto v = args.obj_get("contextLines").get_sint(); v && *v >= 0)
            context_lines = (int)std::min((int64_t)50, *v);
        else if (auto v2 = args.obj_get("contextLines").get_uint(); v2)
            context_lines = (int)std::min((uint64_t)50, *v2);

        int max_results = 500;
        if (auto v = args.obj_get("maxResults").get_sint(); v && *v > 0)
            max_results = (int)std::min((int64_t)10000, *v);
        else if (auto v2 = args.obj_get("maxResults").get_uint(); v2)
            max_results = (int)std::min((uint64_t)10000, *v2);

        // Collect exclude patterns (used when walking a root directory via path)
        std::vector<std::string> exclude_strs;
        {
            auto excl_val = args.obj_get("excludePatterns");
            if (excl_val.is_arr())
            {
                Json::ArrIter it(excl_val);
                while (it.has_next())
                {
                    auto ev = it.next();
                    if (auto s = ev.get_str(); s)
                        exclude_strs.push_back(std::string(*s));
                }
            }
        }

        // Build the list of files to search
        std::vector<std::string> files;
        bool early_error = false;

        auto paths_val = args.obj_get("paths");
        if (paths_val.is_arr())
        {
            // Extended: explicit paths and/or globs — same expansion as edit_files
            Json::ArrIter it(paths_val);
            while (it.has_next() && !early_error)
            {
                auto pv = it.next();
                auto ps = pv.get_str();
                if (!ps) continue;
                std::string path_str(*ps);

                if (globoverlap::contains_glob_pattern_char(path_str))
                {
                    auto matches = expand_glob(path_str);
                    if (matches.empty())
                    {
                        PrintMCPError(context, ac, -32002,
                                      "Glob matched no files: " + path_str);
                        early_error = true;
                        break;
                    }
                    for (const auto &m : matches)
                    {
                        auto vr = validate_path(m, *opts, false);
                        if (!vr.ok)
                        {
                            PrintMCPError(context, ac, -32001, vr.error);
                            early_error = true;
                            break;
                        }
                        files.push_back(vr.canonical);
                    }
                }
                else
                {
                    auto vr = validate_path(path_str, *opts, false);
                    if (!vr.ok)
                    {
                        PrintMCPError(context, ac, -32001, vr.error);
                        early_error = true;
                        break;
                    }
                    files.push_back(vr.canonical);
                }
            }
        }
        else
        {
            // Standard MCP: root directory — walk all files recursively
            auto path_sv = args.obj_get("path").get_str();
            if (!path_sv)
            {
                PrintMCPError(context, ac, -32602,
                              "Missing required param: path or paths");
                return;
            }
            auto vr = validate_path(std::string(*path_sv), *opts, false);
            if (!vr.ok)
            {
                PrintMCPError(context, ac, -32001, vr.error);
                return;
            }
            files = glob_files_in_dir(vr.canonical, {"**/*"}, exclude_strs, 0);
        }

        if (early_error) return;

        if (files.empty())
        {
            PrintMCPTextResult(context, ac, "(no files to search)");
            return;
        }

        // Search each file and aggregate grep-style output
        std::string all_text;
        int total_matches = 0;
        bool truncated = false;

        for (const auto &file_path : files)
        {
            if (total_matches >= max_results)
            {
                truncated = true;
                break;
            }
            auto r = SearchFileMCPCore(file_path.c_str(), pattern, use_regex,
                                        case_insensitive, context_lines,
                                        max_results - total_matches);
            if (r.is_binary || !r.error.empty() || r.text.empty())
                continue;
            all_text += r.text;
            total_matches += r.match_count;
        }

        if (all_text.empty())
        {
            PrintMCPTextResult(context, ac, "(no matches found)");
            return;
        }

        if (truncated)
            all_text += "[truncated at " + std::to_string(max_results) + " matches]\n";
        all_text += "[" + std::to_string(total_matches) + " match"
                 + (total_matches == 1 ? "" : "es") + "]\n";
        PrintMCPTextResult(context, ac, std::move(all_text));
    }
    else if (tool == "glob_search")
    {
        auto path = validate_and_get(args, "path", *opts, false, ac, context);
        if (path.empty()) return;

        NSMutableArray<NSString *> *patterns = [NSMutableArray array];
        {
            auto pats_val = args.obj_get("patterns");
            if (pats_val.is_arr())
            {
                Json::ArrIter it(pats_val);
                while (it.has_next())
                {
                    auto pv = it.next();
                    if (auto s = pv.get_str(); s)
                        [patterns addObject:[NSString stringWithUTF8String:std::string(*s).c_str()]];
                }
            }
            else if (auto s = args.obj_get("pattern").get_str(); s)
            {
                [patterns addObject:[NSString stringWithUTF8String:std::string(*s).c_str()]];
            }
            if ([patterns count] == 0)
            {
                PrintMCPError(context, ac, -32602, "Missing required param: patterns or pattern");
                return;
            }
        }

        NSMutableArray<NSString *> *excludes = [NSMutableArray array];
        {
            auto excl_val = args.obj_get("excludePatterns");
            if (excl_val.is_arr())
            {
                Json::ArrIter it(excl_val);
                while (it.has_next())
                {
                    auto ev = it.next();
                    if (auto s = ev.get_str(); s)
                        [excludes addObject:[NSString stringWithUTF8String:std::string(*s).c_str()]];
                }
            }
        }

        NSInteger maxR = 1000;
        if (auto mv = args.obj_get("max").get_sint(); mv && *mv > 0) maxR = (NSInteger)*mv;
        else if (auto mv2 = args.obj_get("max").get_uint(); mv2) maxR = (NSInteger)*mv2;

        NSString *rootNS = [NSString stringWithUTF8String:path.c_str()];
        GlobFiles(rootNS, patterns, excludes, maxR, context, ac);
    }
    else if (tool == "read_multiple_files")
    {
        auto paths_val = args.obj_get("paths");
        if (!paths_val.is_arr())
        {
            PrintMCPError(context, ac, -32602, "Missing required param: paths (array)");
            return;
        }
        std::vector<std::string> texts;
        Json::ArrIter it(paths_val);
        size_t count = 0;
        while (it.has_next())
        {
            auto pv = it.next();
            auto ps = pv.get_str();
            if (!ps) continue;
            if (++count > kMaxReadMultiple)
            {
                texts.push_back("[error: too many files (max 50)]");
                break;
            }
            auto vr = validate_path(std::string(*ps), *opts, false);
            if (!vr.ok)
            {
                texts.push_back(std::string(*ps) + ":\n[error: " + vr.error + "]");
                continue;
            }
            auto fr = read_file_bytes(vr.canonical);
            if (!fr.ok)
            {
                texts.push_back(vr.canonical + ":\n[error: " + fr.error + "]");
                continue;
            }
            std::string entry = vr.canonical + ":\n";
            if (fr.is_text)
            {
                entry.append(reinterpret_cast<const char *>(fr.data.data()), fr.data.size());
            }
            else
            {
                unsigned long enc_size = CalculateEncodedBufferSize((unsigned long)fr.data.size());
                std::vector<unsigned char> enc(enc_size + 1, 0);
                unsigned long written = EncodeBase64(fr.data.data(), (unsigned long)fr.data.size(),
                                                      enc.data(), enc_size);
                entry += "[binary, base64]\n";
                entry.append(reinterpret_cast<const char *>(enc.data()), written);
            }
            texts.push_back(std::move(entry));
        }
        PrintMCPMultiTextResult(context, ac, texts);
    }
    else if (tool == "list_allowed_directories")
    {
        std::string text;
        for (const auto &dir : opts->allowedDirs)
            text += dir.path + (dir.writable ? " (read-write)\n" : " (read-only)\n");
        PrintMCPTextResult(context, ac,
                            text.empty() ? "(no directories configured — all filesystem access denied)"
                                         : text);
    }
    else
    {
        PrintMCPError(context, ac, -32601, "Unknown tool: " + tool);
    }
}

// ============================================================================
// Tool list — built once at startup
// ============================================================================

static void add_str_prop(Json::MutableDoc &doc, Json::MutableVal props,
                          std::string_view name, std::string_view desc)
{
    auto p = doc.new_obj();
    doc.obj_add(p, "type", doc.new_str("string"));
    if (!desc.empty()) doc.obj_add(p, "description", doc.new_str(desc));
    doc.obj_add(props, name, p);
}

static void add_bool_prop(Json::MutableDoc &doc, Json::MutableVal props,
                           std::string_view name, std::string_view desc)
{
    auto p = doc.new_obj();
    doc.obj_add(p, "type", doc.new_str("boolean"));
    if (!desc.empty()) doc.obj_add(p, "description", doc.new_str(desc));
    doc.obj_add(props, name, p);
}

static void add_int_prop(Json::MutableDoc &doc, Json::MutableVal props,
                          std::string_view name, std::string_view desc)
{
    auto p = doc.new_obj();
    doc.obj_add(p, "type", doc.new_str("integer"));
    if (!desc.empty()) doc.obj_add(p, "description", doc.new_str(desc));
    doc.obj_add(props, name, p);
}

static Json::MutableVal make_req(Json::MutableDoc &doc,
                                  std::initializer_list<std::string_view> req)
{
    auto a = doc.new_arr();
    for (auto r : req) doc.arr_append(a, doc.new_str(r));
    return a;
}

static Json::MutableVal add_tool(Json::MutableDoc &doc, std::string_view name,
                                  std::string_view desc, Json::MutableVal schema)
{
    auto tool = doc.new_obj();
    doc.obj_add(tool, "name",        doc.new_str(name));
    doc.obj_add(tool, "description", doc.new_str(desc));
    doc.obj_add(tool, "inputSchema", schema);
    return tool;
}

static std::string build_tools_list_json()
{
    Json::MutableDoc doc;
    auto tools = doc.new_arr();

    // read_file
    {
        auto props = doc.new_obj();
        add_str_prop(doc, props, "path", "Absolute path to the file");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"path"}));
        doc.arr_append(tools, add_tool(doc, "read_file",
            "Read the complete contents of a file. Returns UTF-8 text or "
            "base64-encoded blob for binary files. Maximum 10 MB.", schema));
    }

    // read_multiple_files
    {
        auto paths_prop = doc.new_obj();
        doc.obj_add(paths_prop, "type", doc.new_str("array"));
        auto items = doc.new_obj();
        doc.obj_add(items, "type", doc.new_str("string"));
        doc.obj_add(paths_prop, "items", items);
        doc.obj_add(paths_prop, "description", doc.new_str("Array of absolute file paths"));
        auto props = doc.new_obj();
        doc.obj_add(props, "paths", paths_prop);
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"paths"}));
        doc.arr_append(tools, add_tool(doc, "read_multiple_files",
            "Read multiple files simultaneously. Each result is prefixed with its path. "
            "Errors are included inline rather than failing the whole call. Maximum 50 files.",
            schema));
    }

    // write_file
    {
        auto props = doc.new_obj();
        add_str_prop(doc, props, "path",    "Absolute path to write");
        add_str_prop(doc, props, "content", "UTF-8 text content to write");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"path", "content"}));
        doc.arr_append(tools, add_tool(doc, "write_file",
            "Create or overwrite a file with the given content. Creates parent directories as needed.",
            schema));
    }

    // edit_file
    {
        auto edit_item_props = doc.new_obj();
        add_str_prop(doc, edit_item_props, "oldText",
            "Text or regex pattern to find (required)");
        add_str_prop(doc, edit_item_props, "newText",
            "Replacement text. Use \\1..\\9 for regex back-references. Default: empty string.");
        add_int_prop(doc, edit_item_props, "limit",
            "Maximum replacements (default 1; 0 = unlimited)");
        add_bool_prop(doc, edit_item_props, "regex",
            "Treat oldText as a POSIX ERE regex pattern (default false)");
        add_bool_prop(doc, edit_item_props, "caseInsensitive",
            "Case-insensitive matching (default false)");
        auto edit_item_schema = doc.new_obj();
        doc.obj_add(edit_item_schema, "type", doc.new_str("object"));
        doc.obj_add(edit_item_schema, "properties", edit_item_props);
        doc.obj_add(edit_item_schema, "required", make_req(doc, {"oldText"}));
        auto edits_prop = doc.new_obj();
        doc.obj_add(edits_prop, "type", doc.new_str("array"));
        doc.obj_add(edits_prop, "items", edit_item_schema);
        doc.obj_add(edits_prop, "description", doc.new_str("Array of edit operations applied in order"));
        auto props = doc.new_obj();
        add_str_prop(doc, props, "path", "Absolute path to the file to edit");
        doc.obj_add(props, "edits", edits_prop);
        add_bool_prop(doc, props, "dryRun", "Show the edit plan without writing (default false)");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"path", "edits"}));
        doc.arr_append(tools, add_tool(doc, "edit_file",
            "Apply text edits to a file. Supports literal and POSIX ERE regex matching, "
            "back-references, case-insensitive mode, and configurable replacement limits. "
            "Writes atomically. Extended beyond standard MCP edit_file.", schema));
    }

    // edit_files (extended — multi-file via literal paths and/or glob patterns)
    {
        auto edit_item_props = doc.new_obj();
        add_str_prop(doc, edit_item_props, "oldText",
            "Text or regex pattern to find (required)");
        add_str_prop(doc, edit_item_props, "newText",
            "Replacement text. Use \\1..\\9 for regex back-references. Default: empty string.");
        add_int_prop(doc, edit_item_props, "limit",
            "Maximum replacements per file (default 1; 0 = unlimited)");
        add_bool_prop(doc, edit_item_props, "regex",
            "Treat oldText as a POSIX ERE regex pattern (default false)");
        add_bool_prop(doc, edit_item_props, "caseInsensitive",
            "Case-insensitive matching (default false)");
        auto edit_item_schema = doc.new_obj();
        doc.obj_add(edit_item_schema, "type", doc.new_str("object"));
        doc.obj_add(edit_item_schema, "properties", edit_item_props);
        doc.obj_add(edit_item_schema, "required", make_req(doc, {"oldText"}));
        auto edits_prop = doc.new_obj();
        doc.obj_add(edits_prop, "type", doc.new_str("array"));
        doc.obj_add(edits_prop, "items", edit_item_schema);
        doc.obj_add(edits_prop, "description", doc.new_str("Array of edit operations applied in order to every resolved file"));
        auto paths_prop = doc.new_obj();
        doc.obj_add(paths_prop, "type", doc.new_str("array"));
        auto paths_items = doc.new_obj();
        doc.obj_add(paths_items, "type", doc.new_str("string"));
        doc.obj_add(paths_prop, "items", paths_items);
        doc.obj_add(paths_prop, "description",
            doc.new_str("Absolute file paths and/or glob patterns (e.g. /src/**/*.cpp). "
                        "Literal paths edit one file each; globs expand to all matching files at runtime. "
                        "Error if a glob matches no files."));
        auto props = doc.new_obj();
        doc.obj_add(props, "paths", paths_prop);
        doc.obj_add(props, "edits", edits_prop);
        add_bool_prop(doc, props, "dryRun", "Show the edit plan per file without writing (default false)");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"paths", "edits"}));
        doc.arr_append(tools, add_tool(doc, "edit_files",
            "[Extended] Apply edits to one or more files specified as literal paths and/or glob patterns. "
            "Glob patterns (e.g. /src/**/*.cpp) expand to all matching files at runtime. "
            "Supports all edit_file options. Returns per-file results in a single response.",
            schema));
    }

    // execute_command (extended — hard-sandboxed shell execution)
    {
        auto props = doc.new_obj();
        add_str_prop(doc, props, "command",
            "Shell command executed via /bin/sh -c. Supports pipes, redirects, "
            "environment variables, and shell built-ins. When the server is started "
            "with --sandbox, the macOS Seatbelt kernel sandbox confines the child "
            "shell process to the allowed directories — stronger than path-validation alone.");
        add_str_prop(doc, props, "workingDirectory",
            "Absolute path to use as the working directory (must be within an allowed "
            "directory). Defaults to the first writable allowed directory.");
        add_int_prop(doc, props, "timeout",
            "Timeout in seconds before the command is killed (default 30, max 60). "
            "On timeout isError is set to true and the exit code is the shell's "
            "termination status.");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"command"}));
        doc.arr_append(tools, add_tool(doc, "execute_command",
            "[Extended] Execute a shell command. Returns stdout as the primary content "
            "item and stderr as a second item when non-empty. Sets isError=true when "
            "the command exits non-zero or times out. When replay is started with "
            "--sandbox, the Seatbelt kernel sandbox enforces filesystem access limits "
            "on the child process — making shell execution safer than soft path-checking.",
            schema));
    }

    // create_directory
    {
        auto props = doc.new_obj();
        add_str_prop(doc, props, "path", "Absolute path to the directory to create");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"path"}));
        doc.arr_append(tools, add_tool(doc, "create_directory",
            "Create a directory and all intermediate parent directories (mkdir -p semantics).",
            schema));
    }

    // list_directory
    {
        auto props = doc.new_obj();
        add_str_prop(doc, props, "path", "Absolute path to the directory");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"path"}));
        doc.arr_append(tools, add_tool(doc, "list_directory",
            "List the immediate children of a directory. Each entry is prefixed with [FILE] or [DIR].",
            schema));
    }

    // directory_tree
    {
        auto props = doc.new_obj();
        add_str_prop(doc, props, "path", "Absolute path to the root directory");
        add_int_prop(doc, props, "depth", "Maximum recursion depth (default 10; 0 = root only)");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"path"}));
        doc.arr_append(tools, add_tool(doc, "directory_tree",
            "Recursively list a directory as a JSON tree. Each node has name, type, and children.",
            schema));
    }

    // move_file
    {
        auto props = doc.new_obj();
        add_str_prop(doc, props, "source",      "Absolute source path");
        add_str_prop(doc, props, "destination",  "Absolute destination path");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"source", "destination"}));
        doc.arr_append(tools, add_tool(doc, "move_file",
            "Move or rename a file or directory.", schema));
    }

    // delete_file
    {
        auto props = doc.new_obj();
        add_str_prop(doc, props, "path", "Absolute path to delete (file or directory)");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"path"}));
        doc.arr_append(tools, add_tool(doc, "delete_file",
            "Delete a file or directory (recursively). No confirmation requested.", schema));
    }

    // search_files — content search (grep-style)
    {
        auto excl_prop = doc.new_obj();
        doc.obj_add(excl_prop, "type", doc.new_str("array"));
        auto excl_items = doc.new_obj();
        doc.obj_add(excl_items, "type", doc.new_str("string"));
        doc.obj_add(excl_prop, "items", excl_items);
        doc.obj_add(excl_prop, "description",
            doc.new_str("Glob patterns to exclude from the search (applied when using path root dir)"));
        auto paths_items = doc.new_obj();
        doc.obj_add(paths_items, "type", doc.new_str("string"));
        auto paths_prop = doc.new_obj();
        doc.obj_add(paths_prop, "type", doc.new_str("array"));
        doc.obj_add(paths_prop, "items", paths_items);
        doc.obj_add(paths_prop, "description",
            doc.new_str("[Extended] Absolute file paths and/or glob patterns to search. "
                        "Overrides path. Globs expand at runtime (e.g. /src/**/*.cpp)."));
        auto props = doc.new_obj();
        add_str_prop(doc, props, "path",
            "Absolute root directory — all files under it are searched recursively. "
            "Required unless paths is provided.");
        doc.obj_add(props, "paths",           paths_prop);
        add_str_prop(doc, props, "pattern",
            "Text or regex pattern to search for in file contents (required)");
        doc.obj_add(props, "excludePatterns", excl_prop);
        add_bool_prop(doc, props, "regex",
            "Treat pattern as a POSIX ERE regex (default false)");
        add_bool_prop(doc, props, "caseInsensitive",
            "Case-insensitive matching (default false)");
        add_int_prop(doc, props, "contextLines",
            "Lines of context before and after each match, like grep -C (default 0, max 50)");
        add_int_prop(doc, props, "maxResults",
            "Maximum total matches to return across all files (default 500, max 10000)");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"pattern"}));
        doc.arr_append(tools, add_tool(doc, "search_files",
            "Search file contents for a text or regex pattern (grep-style). "
            "Returns file:line:content matches. "
            "Provide path to walk a directory recursively, or paths for explicit files/globs. "
            "Supports regex (POSIX ERE), case-insensitive, and context lines. "
            "Binary files are skipped. Extended beyond standard MCP search_files.", schema));
    }

    // get_file_info
    {
        auto props = doc.new_obj();
        add_str_prop(doc, props, "path", "Absolute path to query");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"path"}));
        doc.arr_append(tools, add_tool(doc, "get_file_info",
            "Get metadata for a file or directory: type, size, timestamps, and permissions.",
            schema));
    }

    // list_allowed_directories
    {
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", doc.new_obj());
        doc.arr_append(tools, add_tool(doc, "list_allowed_directories",
            "List the directories this MCP server is allowed to access, "
            "with their access mode (read-only or read-write).", schema));
    }

    // glob_search (extended)
    {
        auto pats_prop = doc.new_obj();
        doc.obj_add(pats_prop, "type", doc.new_str("array"));
        auto pats_items = doc.new_obj();
        doc.obj_add(pats_items, "type", doc.new_str("string"));
        doc.obj_add(pats_prop, "items", pats_items);
        doc.obj_add(pats_prop, "description",
            doc.new_str("Glob patterns relative to path (e.g. **/*.swift, src/*.{cpp,h})"));
        auto excl_prop = doc.new_obj();
        doc.obj_add(excl_prop, "type", doc.new_str("array"));
        auto excl_items = doc.new_obj();
        doc.obj_add(excl_items, "type", doc.new_str("string"));
        doc.obj_add(excl_prop, "items", excl_items);
        auto props = doc.new_obj();
        add_str_prop(doc, props, "path", "Absolute root directory to search");
        add_str_prop(doc, props, "pattern", "Single glob pattern (alternative to patterns array)");
        doc.obj_add(props, "patterns",        pats_prop);
        doc.obj_add(props, "excludePatterns", excl_prop);
        add_int_prop(doc, props, "max", "Maximum results (default 1000; 0 = unlimited)");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"path"}));
        doc.arr_append(tools, add_tool(doc, "glob_search",
            "[Extended] Search files using replay's glob engine. Supports "
            "** (recursive), ? (single char), {a,b} (alternation). "
            "Accepts a single pattern or an array of patterns relative to path.", schema));
    }

    doc.set_root(tools);
    return doc.to_string();
}

// ============================================================================
// Protocol handler — called for each line from stdin
// ============================================================================

static void handle_message(const std::string &line,
                            ReplayContext *context,
                            const MCPServerOptions *opts,
                            bool &initialized)
{
    yyjson_read_err read_err{};
    Json::Document doc = Json::parse(line, YYJSON_READ_NOFLAG, &read_err);
    if (!doc)
    {
        fprintf(stderr, "replay-mcp: JSON parse error: %s\n", read_err.msg);
        ActionContext ac = {nil, -1, "null"};
        PrintMCPError(context, &ac, -32700, "Parse error");
        return;
    }

    Json::Val root = doc.root();
    if (!root.is_obj())
    {
        ActionContext ac = {nil, -1, "null"};
        PrintMCPError(context, &ac, -32600, "Invalid request: root must be object");
        return;
    }

    Json::Val id_val = root.obj_get("id");
    std::string request_id = extract_request_id(id_val);
    bool has_id = id_val.valid();

    auto method_sv = root.obj_get("method").get_str();
    if (!method_sv)
    {
        if (!has_id)
            return;
        ActionContext ac = {nil, -1, request_id};
        PrintMCPError(context, &ac, -32600, "Invalid request: missing method");
        return;
    }
    std::string_view method = *method_sv;

    ActionContext ac = {nil, -1, request_id};

    if (method == "initialize")
    {
        initialized = true;
        Json::MutableDoc resp;
        auto result = resp.new_obj();
        resp.obj_add(result, "protocolVersion", resp.new_str(kProtocolVersion));
        auto caps = resp.new_obj();
        resp.obj_add(caps, "tools", resp.new_obj());
        resp.obj_add(result, "capabilities", caps);
        auto info = resp.new_obj();
        resp.obj_add(info, "name",    resp.new_str(kServerName));
        resp.obj_add(info, "version", resp.new_str(kServerVersion));
        resp.obj_add(result, "serverInfo", info);
        
        std::string response = make_result_response(request_id, resp, result);
        PrintMCPResponse(context, &ac, std::move(response));                                       
        return;
    }

    if (method == "initialized")
        return; // notification — no response

    if (method == "ping")
    {
        Json::MutableDoc resp;
        auto result = resp.new_obj();
        std::string response = make_result_response(request_id, resp, result);
        PrintMCPResponse(context, &ac, std::move(response));
        return;
    }

    if (method == "tools/list")
    {
        static const std::string kToolsJson = build_tools_list_json();
        Json::MutableDoc resp;
        auto result = resp.new_obj();
        resp.obj_add(result, "tools", resp.new_raw(kToolsJson));
        std::string response = make_result_response(request_id, resp, result);
        PrintMCPResponse(context, &ac, std::move(response));
        return;
    }

    if (method == "tools/call")
    {
        Json::Val params = root.obj_get("params");
        if (!params.is_obj())
        {
            PrintMCPError(context, &ac, -32602, "Invalid params");
            return;
        }
        auto name_sv = params.obj_get("name").get_str();
        if (!name_sv)
        {
            PrintMCPError(context, &ac, -32602, "Missing tools/call param: name");
            return;
        }

        // Capture by value for the async block; move doc into shared_ptr so
        // the parsed JSON stays alive until the block completes.
        std::string captured_id   = request_id;
        std::string captured_tool = std::string(*name_sv);
        auto shared_doc = std::make_shared<Json::Document>(std::move(doc));

        AsyncDispatch(^{
            @autoreleasepool {
                ActionContext ac;
                ac.settings     = nil;
                ac.index        = -1;
                ac.mcpRequestID = captured_id;

                Json::Val req_params = shared_doc->root().obj_get("params");
                Json::Val tool_args  = req_params.obj_get("arguments");

                dispatch_mcp_tool(captured_tool, tool_args, context, &ac, opts);
            }
        });
        return;
    }

    if (!has_id)
        return; // unknown notification — silently ignore
    PrintMCPError(context, &ac, -32601, "Method not found: " + std::string(method));
}

// ============================================================================
// Entry point
// ============================================================================

int RunMCPServer(ReplayContext *context, const MCPServerOptions &opts)
{
    assert(context->mcpServer);
    assert(context->outputSerializer != nullptr);

    setvbuf(stdout, nullptr, _IONBF, 0);

    fprintf(stderr, "replay-mcp: starting MCP server (protocol %s)\n", kProtocolVersion);
    if (opts.allowedDirs.empty())
        fprintf(stderr, "replay-mcp: WARNING — no allowed directories configured\n");
    else
        for (const auto &dir : opts.allowedDirs)
            fprintf(stderr, "replay-mcp: allowed %s %s\n",
                    dir.writable ? "[rw]" : "[ro]", dir.path.c_str());

    StartAsyncDispatch(context->councurrencyLimit);

    bool initialized = false;
    std::string line;

    while (std::getline(std::cin, line))
    {
        if (!line.empty())
            handle_message(line, context, &opts, initialized);
    }

    FinishAsyncDispatchAndWait();
    context->outputSerializer->flush();

    fprintf(stderr, "replay-mcp: stdin closed, exiting\n");
    return EXIT_SUCCESS;
}
