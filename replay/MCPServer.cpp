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

#include <dispatch/dispatch.h>
#include "ReplayAction.h"
#include "ReplayActionPrivate.h"
#include "MCPServer.h"
#include "FileSystemHelpers.h"
#include "GlobOverlap.h"
#include "ABase64.h"
#include "yyjson.hpp"
#include "CFStr.h"
#include "CFDict.h"

#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <cassert>

#include <string>
#include <string_view>
#include <vector>
#include <set>
#include <memory>
#include <mutex>
#include <atomic>
#include <fstream>
#include <iostream>

#include "AsyncDispatch.h"
#include "PosixFileOps.h"

#include <unistd.h>
#include <sys/stat.h>
#include <limits.h>
#include <regex>

// Revisions replay speaks, newest first. Element 0 is both the default - answered
// when a client asks for nothing, asks with a non-string, or asks for a revision we
// do not speak - and what the startup banner announces. The lifecycle spec requires
// that fallback to be a revision the server supports and says it SHOULD be the
// latest one, which is why it is the head of this list rather than the tail.
//
// 2025-03-26 is deliberately ABSENT, and that omission is the point rather than an
// oversight. It is the only revision that obliges an implementation to accept
// JSON-RPC batches ("MCP implementations MAY support sending JSON-RPC batches, but
// MUST support receiving JSON-RPC batches"), and replay's read loop is one JSON
// object per line. 2025-06-18 removed the batch requirement again, so skipping the
// revision is the conformant way out; writing a batch parser would satisfy exactly
// one dead revision and nothing before or after it. A client that asks for
// 2025-03-26 is answered with the head of this list, which the spec explicitly
// permits: "Otherwise, the server MUST respond with another protocol version it
// supports."
//
// Dropping it costs nothing load-bearing. Tool annotations are a 2025-03-26 feature,
// but they carry forward unchanged into 2025-06-18 and 2025-11-25, and replay emits
// them regardless of which revision was negotiated.
static constexpr const char *kProtocolVersion = "2025-11-25";
static constexpr std::string_view kSupportedProtocolVersions[] = {
    "2025-11-25", "2025-06-18", "2024-11-05",
};
// Two halves of one invariant: the list is sorted newest-first, and the default is its
// head. Checking only the second would still let a newer revision be appended at the
// tail, which is precisely the shape of the bug this replaces - a default that is not
// actually the latest. Revisions are ISO-8601 dates, so lexicographic order is
// chronological order and a plain string compare is the real test.
static_assert(kSupportedProtocolVersions[0] == std::string_view(kProtocolVersion),
              "kProtocolVersion must be the newest supported revision - the lifecycle "
              "spec says an unrecognized request SHOULD fall back to the server's latest, "
              "and answering the oldest silently strips features the client asked for");
static_assert([] {
                  for (size_t i = 1; i < std::size(kSupportedProtocolVersions); ++i)
                      if (!(kSupportedProtocolVersions[i - 1] > kSupportedProtocolVersions[i]))
                          return false;
                  return true;
              }(),
              "kSupportedProtocolVersions must be sorted newest-first with no duplicates, "
              "so that element 0 is genuinely the latest revision replay speaks");
// Whether the negotiated revision entitles the client to the 2025-06-18 result surface:
// `structuredContent`, `resource_link` content blocks, and `outputSchema` in tools/list.
//
// This is not caution, it is the lifecycle spec's Operation rule - both parties MUST
// "only use capabilities that were successfully negotiated". Sending a resource_link to
// a client that agreed on 2024-11-05 hands it a content type its schema does not define,
// and for search_files/glob_search that is the entire answer: the paths moved out of the
// text block, so an old client would decode a match count and nothing else.
//
// Default true because kProtocolVersion is the latest: a client that never sends
// initialize (or sends a malformed one) is answered the newest revision, so the two
// stay consistent. Set once from initialize, read from the async tool threads, hence
// atomic - stdio is one connection per process, so a single flag is the whole story.
static std::atomic<bool> g_structuredOutputNegotiated{true};

static bool structured_output_negotiated()
{
    return g_structuredOutputNegotiated.load(std::memory_order_relaxed);
}

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
    std::unique_ptr<char, decltype(&free)> raw(
        yyjson_val_write_opts(id_val.raw(), 0, nullptr, &len, &err), free);
    if (raw == nullptr)
        return "null";
    return std::string(raw.get(), len);
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
    return {false, {},
            "Path not allowed: " + r.canonical +
            " is outside the allowed directories (use list_allowed_directories to see them)"};
}

// ============================================================================
// file:// URIs - for resource and resource_link content blocks
// ============================================================================

// RFC 8089 file URI for an absolute POSIX path. Percent-encodes byte by byte so
// UTF-8 survives intact, keeping only the RFC 3986 unreserved set plus '/' as the
// separator. A bare path is not a URI: a filename containing a space, '#', '?' or
// '%' would otherwise yield something the client cannot parse back into the path it
// was given, and these paths come from the filesystem, not from us.
static std::string make_file_uri(std::string_view path)
{
    static constexpr char kHexDigits[] = "0123456789ABCDEF";
    std::string uri = "file://";
    // Guard, not decoration: without a leading '/', the first path segment is parsed as
    // the URI *authority* - "relative/x" becomes host "relative". Every path replay
    // hands out is canonicalized and absolute, but this function is now also fed
    // tool-produced path lists, so make the invariant local instead of assumed.
    if (path.empty() || path.front() != '/')
        uri.push_back('/');
    uri.reserve(uri.size() + path.size() + 16);
    for (unsigned char ch : path)
    {
        bool unreserved = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
                          (ch >= '0' && ch <= '9') ||
                          ch == '-' || ch == '.' || ch == '_' || ch == '~' || ch == '/';
        if (unreserved)
        {
            uri.push_back((char)ch);
        }
        else
        {
            uri.push_back('%');
            uri.push_back(kHexDigits[ch >> 4]);
            uri.push_back(kHexDigits[ch & 0x0F]);
        }
    }
    return uri;
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

// Binary file contents, as an embedded resource content block.
//
// There is no "blob" content block in any MCP revision - the content types are text,
// image, audio, resource_link (2025-06-18+) and resource - and `blob` is a FIELD of a
// resource's contents holding the base64 payload. Emitting {"type":"blob",...} put a
// block on the wire that no conforming client can decode; it typecheck-failed or was
// dropped depending on how strict the client's schema was. The URI is what makes this
// well-formed rather than merely renamed: an embedded resource is identified by it.
std::string MakeMCPBlobResult(const std::string &request_id, const std::string &filePath,
                               std::string base64Data, std::string mimeType)
{
    Json::MutableDoc doc;
    auto resource = doc.new_obj();
    doc.obj_add(resource, "uri",      doc.new_str(make_file_uri(filePath)));
    doc.obj_add(resource, "mimeType", doc.new_str(mimeType));
    doc.obj_add(resource, "blob",     doc.new_str(base64Data));
    auto item = doc.new_obj();
    doc.obj_add(item, "type",     doc.new_str("resource"));
    doc.obj_add(item, "resource", resource);
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

// ============================================================================
// Structured output (spec revision 2025-06-18)
//
// A tool that declares `outputSchema` MUST return `structuredContent` conforming to
// it, so the two are added together, per tool, or not at all.
//
// The spec also says a tool returning structured content SHOULD mirror the serialized
// JSON in a text block. replay deliberately keeps its existing human-readable text
// instead. The purpose of that SHOULD is that a client which cannot read
// structuredContent still receives the data - and replay's text already carries the
// same fields, in the form a language model actually reads. Replacing it with a JSON
// dump would satisfy the letter of the guidance while making every result harder for
// the consumer it exists for. The deviation is confined to the shape of the mirror,
// not to whether the data is present.
// ============================================================================

// Best-effort MIME type from a filename extension, for resource_link blocks. Only the
// types replay is likely to hand back are listed; anything unknown gets no mimeType at
// all, which is valid - the field is optional, and guessing wrong is worse than
// omitting it, because a client may dispatch on it.
static const char *guess_mime_type(std::string_view path)
{
    size_t dot = path.rfind('.');
    if (dot == std::string_view::npos)
        return nullptr;
    // Lowercased before matching: the default macOS volume is case-insensitive, so
    // IMG_0001.JPG and README.MD are ordinary filenames, not edge cases.
    std::string ext;
    for (char ch : path.substr(dot + 1))
        ext.push_back((char)std::tolower((unsigned char)ch));

    if (ext == "txt" || ext == "text")                      return "text/plain";
    if (ext == "md" || ext == "markdown")                   return "text/markdown";
    if (ext == "json")                                      return "application/json";
    // .plist is deliberately absent: on macOS a plist is as often the binary bplist00
    // format as XML, and this function's rule is that a wrong type is worse than none.
    if (ext == "xml")                                       return "application/xml";
    if (ext == "html" || ext == "htm")                      return "text/html";
    if (ext == "css")                                       return "text/css";
    if (ext == "js" || ext == "mjs")                        return "text/javascript";
    if (ext == "py")                                        return "text/x-python";
    if (ext == "swift")                                     return "text/x-swift";
    if (ext == "c" || ext == "h")                           return "text/x-c";
    if (ext == "cpp" || ext == "cc" || ext == "cxx" ||
        ext == "hpp" || ext == "hh" || ext == "mm")         return "text/x-c++";
    if (ext == "m")                                         return "text/x-objcsrc";
    if (ext == "rs")                                        return "text/x-rust";
    if (ext == "go")                                        return "text/x-go";
    if (ext == "sh" || ext == "bash" || ext == "zsh")       return "application/x-sh";
    if (ext == "yml" || ext == "yaml")                      return "application/yaml";
    if (ext == "toml")                                      return "application/toml";
    if (ext == "pdf")                                       return "application/pdf";
    if (ext == "png")                                       return "image/png";
    if (ext == "jpg" || ext == "jpeg")                      return "image/jpeg";
    if (ext == "gif")                                       return "image/gif";
    if (ext == "svg")                                       return "image/svg+xml";
    return nullptr;
}

// Attaches structuredContent to an in-progress result object, if there is any. Raw
// embedding rather than parse-and-rebuild: the caller already serialized a valid
// object and re-parsing it would only add a failure mode.
static void add_structured_content(Json::MutableDoc &doc, Json::MutableVal result,
                                    const std::string &structuredJson)
{
    if (!structuredJson.empty() && structured_output_negotiated())
        doc.obj_add(result, "structuredContent", doc.new_raw(structuredJson));
}

std::string MakeMCPStructuredResult(const std::string &request_id, std::string text,
                                     std::string structuredJson)
{
    Json::MutableDoc doc;
    auto content = doc.new_arr();
    auto item = doc.new_obj();
    doc.obj_add(item, "type", doc.new_str("text"));
    doc.obj_add(item, "text", doc.new_str(text));
    doc.arr_append(content, item);
    auto result = doc.new_obj();
    doc.obj_add(result, "content", content);
    add_structured_content(doc, result, structuredJson);
    return make_result_response(request_id, doc, result);
}

std::string MakeMCPResourceLinkResult(const std::string &request_id, std::string summaryText,
                                       const std::vector<std::string> &paths,
                                       std::string structuredJson)
{
    // A client on 2024-11-05 has neither resource_link nor structuredContent, and for
    // these tools the paths live nowhere else - it would decode a match count and lose
    // the answer entirely. Fall back to the pre-2025-06-18 shape: the whole list,
    // newline-joined, in one text block. Not a degraded answer, just the older one.
    if (!structured_output_negotiated())
    {
        std::string text;
        for (const auto &path : paths)
        {
            text += path;
            text += '\n';
        }
        return make_text_result(request_id, text.empty() ? std::move(summaryText)
                                                         : std::move(text));
    }

    Json::MutableDoc doc;
    auto content = doc.new_arr();

    auto summary = doc.new_obj();
    doc.obj_add(summary, "type", doc.new_str("text"));
    doc.obj_add(summary, "text", doc.new_str(summaryText));
    doc.arr_append(content, summary);

    for (const auto &path : paths)
    {
        // `name` is the basename: the spec's example uses the filename, and a client
        // rendering a list wants something shorter than the absolute path it already
        // has in `uri`.
        size_t slash = path.rfind('/');
        std::string_view base = (slash == std::string::npos)
                                    ? std::string_view(path)
                                    : std::string_view(path).substr(slash + 1);

        auto link = doc.new_obj();
        doc.obj_add(link, "type", doc.new_str("resource_link"));
        doc.obj_add(link, "uri",  doc.new_str(make_file_uri(path)));
        doc.obj_add(link, "name", doc.new_str(base));
        if (const char *mime = guess_mime_type(path))
            doc.obj_add(link, "mimeType", doc.new_str(mime));
        doc.arr_append(content, link);
    }

    auto result = doc.new_obj();
    doc.obj_add(result, "content", content);
    add_structured_content(doc, result, structuredJson);
    return make_result_response(request_id, doc, result);
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
        if (c == 0)
            return false;
        size_t seqLen;
        if      ((c & 0x80u) == 0x00u)
            seqLen = 1;
        else if ((c & 0xE0u) == 0xC0u)
            seqLen = 2;
        else if ((c & 0xF0u) == 0xE0u)
            seqLen = 3;
        else if ((c & 0xF8u) == 0xF0u)
            seqLen = 4;
        else
            return false;
        for (size_t j = 1; j < seqLen; j++)
        {
            if (i + j >= len || (data[i + j] & 0xC0u) != 0x80u)
                return false;
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

    // structuredContent: the two streams and the status, unmangled. The text blocks
    // above interleave stdout with a "[exit code: N]" footer and prefix stderr with
    // "[stderr]", which is right for a reader and wrong for a parser - a caller that
    // wants the raw stdout should not have to strip a footer off it.
    auto result = doc.new_obj();
    doc.obj_add(result, "content", content);
    if (structured_output_negotiated())
    {
        auto structured = doc.new_obj();
        doc.obj_add(structured, "stdout",   doc.new_str(r.stdout_text));
        doc.obj_add(structured, "stderr",   doc.new_str(r.stderr_text));
        doc.obj_add(structured, "exitCode", doc.new_sint(r.exit_code));
        doc.obj_add(structured, "timedOut", doc.new_bool(r.timed_out));
        doc.obj_add(result, "structuredContent", structured);
    }
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
        if (path.empty())
            return;
        ReadFile(path, context, ac);
    }
    else if (tool == "list_directory")
    {
        auto path = validate_and_get(args, "path", *opts, false, ac, context);
        if (path.empty())
            return;
        ListDirectory(path, context, ac);
    }
    else if (tool == "directory_tree")
    {
        auto path = validate_and_get(args, "path", *opts, false, ac, context);
        if (path.empty())
            return;
        intptr_t depth = -1;  // -1 = unlimited (standard MCP default)
        if (auto dv = args.obj_get("depth").get_sint(); dv)
            depth = (intptr_t)*dv;
        else if (auto dv2 = args.obj_get("depth").get_uint(); dv2)
            depth = (intptr_t)*dv2;
        DirectoryTree(path, depth, context, ac);
    }
    else if (tool == "get_file_info")
    {
        auto path = validate_and_get(args, "path", *opts, false, ac, context);
        if (path.empty())
            return;
        GetFileInfo(path, context, ac);
    }
    else if (tool == "write_file")
    {
        auto path = validate_and_get(args, "path", *opts, true, ac, context);
        if (path.empty())
            return;
        auto content_sv = args.obj_get("content").get_str();
        if (!content_sv)
        {
            PrintMCPError(context, ac, -32602, "Missing required param: content");
            return;
        }
        posix_mkdir_p(posix_parent_dir(path));
        CreateFile(path, std::string(*content_sv), context, ac);
    }
    else if (tool == "create_directory")
    {
        auto path = validate_and_get(args, "path", *opts, true, ac, context);
        if (path.empty())
            return;
        CreateDirectory(path, context, ac);
    }
    else if (tool == "move_file")
    {
        auto src = validate_and_get(args, "source", *opts, true, ac, context);
        if (src.empty())
            return;
        auto dst = validate_and_get(args, "destination", *opts, true, ac, context);
        if (dst.empty())
            return;
        posix_mkdir_p(posix_parent_dir(dst));
        MoveItem(src, dst, context, ac);
    }
    else if (tool == "delete_file")
    {
        auto path = validate_and_get(args, "path", *opts, true, ac, context);
        if (path.empty())
            return;
        DeleteItem(path, context, ac);
    }
    else if (tool == "edit_file")
    {
        // path validation: need write unless dry-run
        bool action_dry_run = false;
        if (auto dv = args.obj_get("dryRun").get_bool(); dv)
            action_dry_run = *dv;

        auto path_sv = args.obj_get("path").get_str();
        if (!path_sv)
        {
            PrintMCPError(context, ac, -32602, "Missing required param: path");
            return;
        }
        auto vr = validate_path(std::string(*path_sv), *opts, !action_dry_run);
        if (!vr.ok)
        {
            PrintMCPError(context, ac, -32001, vr.error);
            return;
        }

        auto edits_val = args.obj_get("edits");
        if (!edits_val.is_arr())
        {
            PrintMCPError(context, ac, -32602, "Missing required param: edits (array)");
            return;
        }

        std::vector<FileEdit> edits;
        Json::ArrIter it(edits_val);
        while (it.has_next())
        {
            auto ev = it.next();
            if (!ev.is_obj())
                continue;
            auto old_sv = ev.obj_get("oldText").get_str();
            if (!old_sv)
                continue;
            FileEdit fe;
            fe.old_text = std::string(*old_sv);
            if (auto ns = ev.obj_get("newText").get_str(); ns)
                fe.new_text = std::string(*ns);
            if (auto lv = ev.obj_get("limit").get_sint(); lv)
                fe.limit = (int)*lv;
            else if (auto lv2 = ev.obj_get("limit").get_uint(); lv2)
                fe.limit = (int)*lv2;
            if (auto rv = ev.obj_get("isRegex").get_bool(); rv)
                fe.use_regex = *rv;
            if (auto cv = ev.obj_get("caseInsensitive").get_bool(); cv)
                fe.case_insensitive = *cv;
            edits.push_back(std::move(fe));
        }

        EditFile(vr.canonical, edits, action_dry_run, context, ac);
    }
    else if (tool == "edit_files")
    {
        bool action_dry_run = false;
        if (auto dv = args.obj_get("dryRun").get_bool(); dv)
            action_dry_run = *dv;

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

        // Build edits array
        std::vector<FileEdit> edits;
        {
            Json::ArrIter it(edits_val);
            while (it.has_next())
            {
                auto ev = it.next();
                if (!ev.is_obj())
                    continue;
                auto old_sv = ev.obj_get("oldText").get_str();
                if (!old_sv)
                    continue;
                FileEdit fe;
                fe.old_text = std::string(*old_sv);
                if (auto ns = ev.obj_get("newText").get_str(); ns)
                    fe.new_text = std::string(*ns);
                if (auto lv = ev.obj_get("limit").get_sint(); lv)
                    fe.limit = (int)*lv;
                else if (auto lv2 = ev.obj_get("limit").get_uint(); lv2)
                    fe.limit = (int)*lv2;
                if (auto rv = ev.obj_get("isRegex").get_bool(); rv)
                    fe.use_regex = *rv;
                if (auto cv = ev.obj_get("caseInsensitive").get_bool(); cv)
                    fe.case_insensitive = *cv;
                edits.push_back(std::move(fe));
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
                if (!ps)
                    continue;
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
            if (early_error)
                return;
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
            auto r = EditFileMCPCore(path, edits, action_dry_run);
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

        CFMutableDict execSettings;
        execSettings.SetValue(CFSTR("workingDirectory"), CFStr(working_dir));
        execSettings.SetValue(CFSTR("timeout"), (int64_t)timeout_sec);
        ac->settings = ActionStep((CFDictionaryRef)execSettings);
        ExcecuteTool("/bin/sh", {"-c", command}, context, ac);
    }
    else if (tool == "search_files")
    {
        // Standard MCP: case-insensitive basename substring match (files and directories).
        // Canonical params: directory / nameContains / excludeGlobs.
        // The MCP-spec names path / pattern / excludePatterns are accepted as silent
        // aliases (not advertised in the schema) because agents may construct them from
        // pre-training. Canonical names win when both are present.
        auto directory_string = args.obj_get("directory").get_str();
        if (!directory_string)
            directory_string = args.obj_get("path").get_str(); // legacy alias
        if (!directory_string)
        {
            PrintMCPError(context, ac, -32602, "Missing required param: directory");
            return;
        }

        auto name_substring = args.obj_get("nameContains").get_str();
        if (!name_substring)
            name_substring = args.obj_get("pattern").get_str(); // legacy alias
        if (!name_substring)
        {
            PrintMCPError(context, ac, -32602, "Missing required param: nameContains");
            return;
        }

        auto directory_validation = validate_path(std::string(*directory_string), *opts, false);
        if (!directory_validation.ok)
        {
            PrintMCPError(context, ac, -32001, directory_validation.error);
            return;
        }

        std::vector<std::string> exclude_globs;
        {
            auto exclude_value = args.obj_get("excludeGlobs");
            if (!exclude_value.is_arr())
                exclude_value = args.obj_get("excludePatterns"); // legacy alias
            if (exclude_value.is_arr())
            {
                Json::ArrIter exclude_iterator(exclude_value);
                while (exclude_iterator.has_next())
                {
                    auto exclude_entry = exclude_iterator.next();
                    if (auto exclude_string = exclude_entry.get_str(); exclude_string)
                        exclude_globs.push_back(std::string(*exclude_string));
                }
            }
        }

        auto matches = find_entries_by_name(directory_validation.canonical,
                                            std::string(*name_substring), exclude_globs, 0);

        // The paths now travel as resource_link blocks and in structuredContent, so the
        // text block carries only the count - repeating the whole list a third time
        // would triple the payload for nothing.
        Json::MutableDoc doc;
        auto match_arr = doc.new_arr();
        for (const auto &match_path : matches)
            doc.arr_append(match_arr, doc.new_str(match_path));
        auto structured = doc.new_obj();
        doc.obj_add(structured, "matches", match_arr);
        doc.obj_add(structured, "count",   doc.new_sint((int64_t)matches.size()));
        doc.set_root(structured);

        std::string summary = matches.empty()
            ? std::string("(no matches found)")
            : "[" + std::to_string(matches.size()) + " match" +
              (matches.size() == 1 ? "" : "es") + "]";
        PrintMCPResourceLinkResult(context, ac, std::move(summary), matches, doc.to_string());
    }
    else if (tool == "grep_files")
    {
        // [ext] Content search (grep-style). Vocabulary (2.1):
        //   regex        — ECMAScript regex searched in file CONTENTS (required, always regex)
        //   directory    — root dir, walked recursively (optional if every glob is absolute)
        //   globs        — file globs; relative globs resolve UNDER directory, absolute
        //                  globs (starting with '/') are honored as-is. Omit to search
        //                  every file under directory.
        //   excludeGlobs — glob exclusions, honored in every mode
        //   caseInsensitive, contextLines, maxResults
        //
        // Behavior notes vs. the non-MCP replay glob engine: relative globs are NEVER
        // resolved against the process cwd here — only against the validated directory
        // root (or, absent a directory, each allowed directory). Out-of-bounds matches
        // are skipped, not fatal, since this is a read-only search.

        // --- regex (required string). Reject the removed boolean flag with a clear hint.
        auto regex_value = args.obj_get("regex");
        auto regex_string = regex_value.get_str();
        if (!regex_string)
        {
            if (regex_value.get_bool().has_value())
                PrintMCPError(context, ac, -32602,
                    "regex is now the search pattern string, not a boolean flag — "
                    "pass the ECMAScript (JavaScript) regex pattern as a string");
            else
                PrintMCPError(context, ac, -32602,
                    "Missing required param: regex (the ECMAScript regex search pattern)");
            return;
        }
        std::string pattern(*regex_string);

        bool case_insensitive = false;
        if (auto case_insensitive_value = args.obj_get("caseInsensitive").get_bool();
            case_insensitive_value)
            case_insensitive = *case_insensitive_value;

        int context_lines = 0;
        if (auto signed_context = args.obj_get("contextLines").get_sint();
            signed_context && *signed_context >= 0)
            context_lines = (int)std::min((int64_t)50, *signed_context);
        else if (auto unsigned_context = args.obj_get("contextLines").get_uint();
                 unsigned_context)
            context_lines = (int)std::min((uint64_t)50, *unsigned_context);

        int max_results = 500;
        if (auto signed_max = args.obj_get("maxResults").get_sint();
            signed_max && *signed_max > 0)
            max_results = (int)std::min((int64_t)10000, *signed_max);
        else if (auto unsigned_max = args.obj_get("maxResults").get_uint(); unsigned_max)
            max_results = (int)std::min((uint64_t)10000, *unsigned_max);

        // --- Validate the regex once, up front (ECMAScript / std::regex). Since
        //     grep_files is always-regex now, an invalid pattern must be a hard
        //     error — not a silent per-file skip.
        {
            try
            {
                auto syntax = std::regex::ECMAScript;
                if (case_insensitive)
                    syntax |= std::regex::icase;
                std::regex compiled_regex(pattern, syntax);
            }
            catch (const std::regex_error &regex_error)
            {
                PrintMCPError(context, ac, -32603,
                              std::string("Invalid regex: ") + regex_error.what());
                return;
            }
        }

        // --- excludeGlobs
        std::vector<std::string> exclude_globs;
        {
            auto exclude_value = args.obj_get("excludeGlobs");
            if (exclude_value.is_arr())
            {
                Json::ArrIter exclude_iterator(exclude_value);
                while (exclude_iterator.has_next())
                {
                    auto exclude_entry = exclude_iterator.next();
                    if (auto exclude_string = exclude_entry.get_str(); exclude_string)
                        exclude_globs.push_back(std::string(*exclude_string));
                }
            }
        }

        // --- directory (optional root, validated if present)
        std::string root_directory;
        bool have_directory = false;
        if (auto directory_string = args.obj_get("directory").get_str(); directory_string)
        {
            auto directory_validation = validate_path(std::string(*directory_string), *opts, false);
            if (!directory_validation.ok)
            {
                PrintMCPError(context, ac, -32001, directory_validation.error);
                return;
            }
            root_directory = directory_validation.canonical;
            have_directory = true;
        }

        // --- globs: split into relative (anchored under directory) and absolute (as-is)
        std::vector<std::string> relative_globs;
        std::vector<std::string> absolute_globs;
        bool have_globs = false;
        if (auto globs_value = args.obj_get("globs"); globs_value.is_arr())
        {
            Json::ArrIter glob_iterator(globs_value);
            while (glob_iterator.has_next())
            {
                auto glob_entry = glob_iterator.next();
                auto glob_string = glob_entry.get_str();
                if (!glob_string)
                    continue;
                have_globs = true;
                std::string glob_pattern(*glob_string);
                if (!glob_pattern.empty() && glob_pattern.front() == '/')
                    absolute_globs.push_back(std::move(glob_pattern));
                else
                    relative_globs.push_back(std::move(glob_pattern));
            }
        }

        if (!have_directory && !have_globs)
        {
            PrintMCPError(context, ac, -32602,
                          "Provide directory and/or globs to select files to search");
            return;
        }
        if (!have_directory && !relative_globs.empty() && opts->allowedDirs.empty())
        {
            PrintMCPError(context, ac, -32001,
                          "Relative globs require a directory: no allowed directories configured");
            return;
        }

        // --- Collect the candidate files (deduped + sorted via set), honoring excludeGlobs.
        std::set<std::string> candidate_files;

        // Relative globs (or a directory-only walk) resolve under the directory root, or —
        // when no directory is given — under the project directory (the first allowed
        // directory, conceptually the working/project dir for this MCP server session).
        // They are never resolved against the process working directory.
        std::vector<std::string> walk_patterns = relative_globs;
        if (!have_globs)
            walk_patterns.push_back("**/*"); // directory-only mode: search the whole tree
        if (!walk_patterns.empty())
        {
            const std::string &walk_root =
                have_directory ? root_directory : opts->allowedDirs.front().path;
            auto matched_files = glob_files_in_dir(walk_root, walk_patterns, exclude_globs, 0);
            candidate_files.insert(matched_files.begin(), matched_files.end());
        }

        // Absolute globs / literal absolute paths are honored as-is, independent of directory.
        if (!absolute_globs.empty())
        {
            auto matched_files = search_files(absolute_globs, exclude_globs, 0);
            candidate_files.insert(matched_files.begin(), matched_files.end());
        }

        // Validate every candidate against the allowed dirs; skip (don't abort) any that
        // escape — e.g. an absolute glob or a symlink pointing outside the sandbox.
        std::vector<std::string> files;
        int skipped_outside = 0;
        for (const auto &candidate_path : candidate_files)
        {
            auto candidate_validation = validate_path(candidate_path, *opts, false);
            if (candidate_validation.ok)
                files.push_back(std::move(candidate_validation.canonical));
            else
                ++skipped_outside;
        }

        auto skipped_note = [&](const char *separator) -> std::string {
            if (skipped_outside == 0)
                return {};
            return std::string(separator) + "[" + std::to_string(skipped_outside) +
                   " path(s) skipped: outside allowed directories]";
        };

        // Search each file and aggregate grep-style output
        std::string all_text;
        int total_matches = 0;
        bool truncated = false;
        std::vector<MCPGrepMatch> all_matches;

        // structuredContent is emitted on EVERY success path, including the two empty
        // ones below. A tool that declares an outputSchema MUST return conforming
        // structuredContent, and "nothing matched" is a valid answer with an empty
        // array - not an excuse to omit the field. Declared before the files.empty()
        // early return for exactly that reason: the first version of this sat below it
        // and left that one path non-conforming.
        auto build_grep_structured = [&]() -> std::string {
            Json::MutableDoc doc;
            auto match_arr = doc.new_arr();
            for (const auto &match : all_matches)
            {
                auto entry = doc.new_obj();
                doc.obj_add(entry, "path",    doc.new_str(match.path));
                doc.obj_add(entry, "line",    doc.new_sint(match.line));
                doc.obj_add(entry, "text",    doc.new_str(match.text));
                doc.obj_add(entry, "isMatch", doc.new_bool(match.is_match));
                doc.arr_append(match_arr, entry);
            }
            auto structured = doc.new_obj();
            doc.obj_add(structured, "matches",   match_arr);
            doc.obj_add(structured, "count",     doc.new_sint(total_matches));
            doc.obj_add(structured, "truncated", doc.new_bool(truncated));
            doc.obj_add(structured, "skipped",   doc.new_sint((int64_t)skipped_outside));
            doc.set_root(structured);
            return doc.to_string();
        };

        if (files.empty())
        {
            PrintMCPStructuredResult(context, ac, "(no files to search)" + skipped_note(" "),
                                      build_grep_structured());
            return;
        }

        for (const auto &file_path : files)
        {
            if (total_matches >= max_results)
            {
                truncated = true;
                break;
            }
            auto grep_result = GrepFileMCPCore(file_path, pattern, /*use_regex*/ true,
                                               case_insensitive, context_lines,
                                               max_results - total_matches);
            if (grep_result.is_binary || !grep_result.error.empty() || grep_result.text.empty())
                continue;
            all_text += grep_result.text;
            total_matches += grep_result.match_count;
            all_matches.insert(all_matches.end(),
                               std::make_move_iterator(grep_result.matches.begin()),
                               std::make_move_iterator(grep_result.matches.end()));
        }

        // The loop above only notices truncation when a file is left unvisited, which
        // misses the common case entirely: one file whose own matches hit the cap
        // inside GrepFileMCPCore. Reaching the cap at all means there may be more, so
        // report it - the same "err toward there-may-be-more" rule glob_search uses,
        // and the same reason: a false negative silently hides matches.
        if (total_matches >= max_results)
            truncated = true;

        if (all_text.empty())
        {
            PrintMCPStructuredResult(context, ac, "(no matches found)" + skipped_note("\n"),
                                      build_grep_structured());
            return;
        }

        if (truncated)
            all_text += "[truncated at " + std::to_string(max_results) + " matches]\n";
        all_text += "[" + std::to_string(total_matches) + " match"
                 + (total_matches == 1 ? "" : "es") + "]\n";
        all_text += skipped_note("");
        PrintMCPStructuredResult(context, ac, std::move(all_text), build_grep_structured());
    }
    else if (tool == "glob_search")
    {
        auto directory = validate_and_get(args, "directory", *opts, false, ac, context);
        if (directory.empty())
            return;

        std::vector<std::string> globs;
        {
            auto globs_value = args.obj_get("globs");
            if (globs_value.is_arr())
            {
                Json::ArrIter glob_iterator(globs_value);
                while (glob_iterator.has_next())
                {
                    auto glob_entry = glob_iterator.next();
                    if (auto glob_string = glob_entry.get_str(); glob_string)
                        globs.push_back(std::string(*glob_string));
                }
            }
            if (globs.empty())
            {
                PrintMCPError(context, ac, -32602,
                              "Missing required param: globs (array of glob patterns)");
                return;
            }
        }

        std::vector<std::string> exclude_globs;
        {
            auto exclude_value = args.obj_get("excludeGlobs");
            if (exclude_value.is_arr())
            {
                Json::ArrIter exclude_iterator(exclude_value);
                while (exclude_iterator.has_next())
                {
                    auto exclude_entry = exclude_iterator.next();
                    if (auto exclude_string = exclude_entry.get_str(); exclude_string)
                        exclude_globs.push_back(std::string(*exclude_string));
                }
            }
        }

        intptr_t max_results = 1000;
        if (auto signed_max = args.obj_get("max").get_sint(); signed_max && *signed_max > 0)
            max_results = (intptr_t)*signed_max;
        else if (auto unsigned_max = args.obj_get("max").get_uint(); unsigned_max)
            max_results = (intptr_t)*unsigned_max;

        GlobFiles(directory, globs, exclude_globs, max_results, context, ac);
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
            if (!ps)
                continue;
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
                // Deliberately NOT the embedded-resource block that read_file now uses.
                // This tool's contract is one text block per path, concatenated, and a
                // resource block cannot be concatenated into a string. Inlining base64
                // in text is legal - a text block may hold anything - unlike the old
                // {"type":"blob"}, which was not a content type at all. Switching this
                // tool would mean returning an interleaved content array (text,
                // resource, text, ...) and re-cutting the per-file error reporting that
                // rides on the same string; that is a separate change, not a fix.
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
        Json::MutableDoc doc;
        auto dirs = doc.new_arr();
        for (const auto &dir : opts->allowedDirs)
        {
            text += dir.path + (dir.writable ? " (read-write)\n" : " (read-only)\n");
            auto entry = doc.new_obj();
            doc.obj_add(entry, "path",     doc.new_str(dir.path));
            doc.obj_add(entry, "writable", doc.new_bool(dir.writable));
            doc.arr_append(dirs, entry);
        }
        auto structured = doc.new_obj();
        doc.obj_add(structured, "directories", dirs);
        doc.set_root(structured);

        PrintMCPStructuredResult(context, ac,
                                  text.empty() ? "(no directories configured — all filesystem access denied)"
                                               : text,
                                  doc.to_string());
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
    if (!desc.empty())
        doc.obj_add(p, "description", doc.new_str(desc));
    doc.obj_add(props, name, p);
}

static void add_bool_prop(Json::MutableDoc &doc, Json::MutableVal props,
                           std::string_view name, std::string_view desc)
{
    auto p = doc.new_obj();
    doc.obj_add(p, "type", doc.new_str("boolean"));
    if (!desc.empty())
        doc.obj_add(p, "description", doc.new_str(desc));
    doc.obj_add(props, name, p);
}

static void add_int_prop(Json::MutableDoc &doc, Json::MutableVal props,
                          std::string_view name, std::string_view desc)
{
    auto p = doc.new_obj();
    doc.obj_add(p, "type", doc.new_str("integer"));
    if (!desc.empty())
        doc.obj_add(p, "description", doc.new_str(desc));
    doc.obj_add(props, name, p);
}

static Json::MutableVal make_req(Json::MutableDoc &doc,
                                  std::initializer_list<std::string_view> req)
{
    auto a = doc.new_arr();
    for (auto r : req) doc.arr_append(a, doc.new_str(r));
    return a;
}

// MCP tool annotations (spec revision 2025-03-26). These are behavior hints the
// client uses to decide how hard to gate a tool, and they are load-bearing, not
// documentation: a host that derives its permission prompts from readOnlyHint asks
// the user before every tool that does not positively claim to be read-only. A
// wrong hint here is a missing prompt (or a pointless one), so keep them honest.
//
// destructiveHint and idempotentHint are only meaningful for a mutating tool, so
// they are emitted only when read_only is false - exactly as the spec describes
// them. Every tool must state its hints: add_tool takes them as a required
// argument so a new tool cannot be added without deciding what it does.
struct ToolHints {
    bool read_only;
    bool destructive;
    bool idempotent;
    bool open_world;
};

// Observes the sandbox it is already confined to; changes nothing.
static constexpr ToolHints kObserves     { .read_only = true,  .destructive = false, .idempotent = false, .open_world = false };
// Adds something that was not there; repeating it lands on the same state.
static constexpr ToolHints kCreates      { .read_only = false, .destructive = false, .idempotent = true,  .open_world = false };
// Replaces a file's contents wholesale; the same call twice leaves the same bytes.
static constexpr ToolHints kOverwrites   { .read_only = false, .destructive = true,  .idempotent = true,  .open_world = false };
// Changes or removes what is already there, and a repeat is not a no-op.
static constexpr ToolHints kMutates      { .read_only = false, .destructive = true,  .idempotent = false, .open_world = false };
// Destroys what is there, but deleting an already-deleted path succeeds and changes
// nothing (DeleteItem reports success when the path is already gone), so a repeat
// call has no additional effect - destructive and idempotent, like HTTP DELETE.
static constexpr ToolHints kRemoves      { .read_only = false, .destructive = true,  .idempotent = true,  .open_world = false };
// Arbitrary shell: anything the kernel sandbox permits, including the network.
static constexpr ToolHints kRunsCommands { .read_only = false, .destructive = true,  .idempotent = false, .open_world = true  };

// Must build a FRESH object per tool: yyjson_mut_val nodes are intrusive list
// nodes carrying their own sibling pointer, so hoisting one shared annotations
// object onto several tools would splice the member chains and silently corrupt
// the document rather than duplicating a subtree.
static Json::MutableVal make_annotations(Json::MutableDoc &doc, const ToolHints &hints)
{
    auto annotations = doc.new_obj();
    doc.obj_add(annotations, "readOnlyHint", doc.new_bool(hints.read_only));
    if (!hints.read_only) {
        doc.obj_add(annotations, "destructiveHint", doc.new_bool(hints.destructive));
        doc.obj_add(annotations, "idempotentHint",  doc.new_bool(hints.idempotent));
    }
    doc.obj_add(annotations, "openWorldHint", doc.new_bool(hints.open_world));
    return annotations;
}

// outputSchema is optional and defaults to absent. Declaring one is a promise: the
// spec says a server that publishes an output schema MUST return conforming
// structuredContent, so a tool only gets a schema here if its handler also builds the
// matching object. The two are reviewed as a pair.
static Json::MutableVal add_tool(Json::MutableDoc &doc, std::string_view name,
                                  std::string_view desc, Json::MutableVal schema,
                                  const ToolHints &hints,
                                  Json::MutableVal outputSchema = {})
{
    auto tool = doc.new_obj();
    doc.obj_add(tool, "name",        doc.new_str(name));
    doc.obj_add(tool, "description", doc.new_str(desc));
    doc.obj_add(tool, "inputSchema", schema);
    if (outputSchema.valid())
        doc.obj_add(tool, "outputSchema", outputSchema);
    doc.obj_add(tool, "annotations", make_annotations(doc, hints));
    return tool;
}

// ---------------------------------------------------------------------------
// outputSchema builders - one per tool that declares one.
//
// Kept next to each other rather than inline in build_tools_list_json so the shapes
// can be compared at a glance against the structuredContent the handlers actually
// emit. A drift between the two is a spec violation, not a cosmetic mismatch.
//
// NEVER attach one MutableVal to two parents. yyjson_mut_val nodes are intrusive list
// nodes carrying their own sibling pointer, so obj_add writes val->next every time:
// adding the same node twice silently REPLACES whatever followed it in the first
// parent. It stays well-formed JSON and still validates, which is why it survives
// review - the loss is a sibling key, not a parse error. Two identical-looking
// subtrees must each be built fresh. (Same hazard as make_annotations above.)
// ---------------------------------------------------------------------------

// A property that is a plain typed scalar, with a description.
static void add_typed_prop(Json::MutableDoc &doc, Json::MutableVal props,
                            std::string_view name, std::string_view type,
                            std::string_view desc)
{
    auto prop = doc.new_obj();
    doc.obj_add(prop, "type",        doc.new_str(type));
    doc.obj_add(prop, "description", doc.new_str(desc));
    doc.obj_add(props, name, prop);
}

// An array-of-strings property.
static void add_string_array_prop(Json::MutableDoc &doc, Json::MutableVal props,
                                   std::string_view name, std::string_view desc)
{
    auto items = doc.new_obj();
    doc.obj_add(items, "type", doc.new_str("string"));
    auto prop = doc.new_obj();
    doc.obj_add(prop, "type",        doc.new_str("array"));
    doc.obj_add(prop, "items",       items);
    doc.obj_add(prop, "description", doc.new_str(desc));
    doc.obj_add(props, name, prop);
}

// Wraps a properties object into a closed object schema with the given required keys.
static Json::MutableVal make_object_schema(Json::MutableDoc &doc, Json::MutableVal props,
                                            std::initializer_list<std::string_view> required)
{
    auto schema = doc.new_obj();
    doc.obj_add(schema, "type",       doc.new_str("object"));
    doc.obj_add(schema, "properties", props);
    doc.obj_add(schema, "required",   make_req(doc, required));
    return schema;
}

// The shared shape of the two path-listing tools: the matches, how many, and whether
// the list was cut short. `truncated` exists because glob_search caps its result set
// and used to do so silently - a caller could not tell a complete answer of exactly
// `max` entries from a truncated one.
static Json::MutableVal make_matches_schema(Json::MutableDoc &doc, bool with_truncated)
{
    auto props = doc.new_obj();
    add_string_array_prop(doc, props, "matches", "Absolute paths of the matching entries");
    add_typed_prop(doc, props, "count", "integer", "Number of matches returned");
    if (!with_truncated)
        return make_object_schema(doc, props, {"matches", "count"});
    add_typed_prop(doc, props, "truncated", "boolean",
        "True when the result set hit the 'max' cap and more matches may exist");
    return make_object_schema(doc, props, {"matches", "count", "truncated"});
}

static Json::MutableVal make_get_file_info_output(Json::MutableDoc &doc)
{
    auto type_prop = doc.new_obj();
    doc.obj_add(type_prop, "type", doc.new_str("string"));
    auto type_enum = doc.new_arr();
    for (auto v : {"file", "directory", "symlink", "other"})
        doc.arr_append(type_enum, doc.new_str(v));
    doc.obj_add(type_prop, "enum", type_enum);
    doc.obj_add(type_prop, "description", doc.new_str(
        "Entry kind. Symlinks are reported as 'symlink' rather than followed."));

    auto props = doc.new_obj();
    add_typed_prop(doc, props, "path", "string", "Canonical absolute path");
    doc.obj_add(props, "type", type_prop);
    add_typed_prop(doc, props, "size", "integer", "Size in bytes");
    add_typed_prop(doc, props, "created", "string",
        "Creation time, ISO-8601 UTC (birth time, falling back to ctime)");
    add_typed_prop(doc, props, "modified", "string", "Modification time, ISO-8601 UTC");
    add_typed_prop(doc, props, "permissions", "string",
        "Ten-character ls-style mode string, e.g. -rw-r--r--");
    return make_object_schema(doc, props,
        {"path", "type", "size", "created", "modified", "permissions"});
}

static Json::MutableVal make_list_directory_output(Json::MutableDoc &doc)
{
    auto entry_type = doc.new_obj();
    doc.obj_add(entry_type, "type", doc.new_str("string"));
    auto entry_enum = doc.new_arr();
    doc.arr_append(entry_enum, doc.new_str("file"));
    doc.arr_append(entry_enum, doc.new_str("directory"));
    doc.obj_add(entry_type, "enum", entry_enum);

    auto entry_props = doc.new_obj();
    add_typed_prop(doc, entry_props, "name", "string", "Entry name, not a full path");
    doc.obj_add(entry_props, "type", entry_type);

    auto entries = doc.new_obj();
    doc.obj_add(entries, "type",  doc.new_str("array"));
    doc.obj_add(entries, "items", make_object_schema(doc, entry_props, {"name", "type"}));
    doc.obj_add(entries, "description", doc.new_str("Directory entries, alphabetically sorted"));

    auto props = doc.new_obj();
    doc.obj_add(props, "entries", entries);
    return make_object_schema(doc, props, {"entries"});
}

// Recursive, so it needs $defs plus a $ref - the node type contains an array of
// itself. JSON Schema 2020-12 is the default dialect from 2025-11-25 on, so no
// $schema keyword is needed to select it.
static Json::MutableVal make_directory_tree_output(Json::MutableDoc &doc)
{
    // Built per call, not hoisted: the node schema and the root schema each need their
    // own "type" property object. Sharing one would splice the member chains and drop a
    // sibling key from whichever parent got it first - see the warning above.
    auto make_node_type = [&doc] {
        auto node_type = doc.new_obj();
        doc.obj_add(node_type, "type", doc.new_str("string"));
        auto node_enum = doc.new_arr();
        doc.arr_append(node_enum, doc.new_str("file"));
        doc.arr_append(node_enum, doc.new_str("directory"));
        doc.obj_add(node_type, "enum", node_enum);
        return node_type;
    };

    auto self_ref = doc.new_obj();
    doc.obj_add(self_ref, "$ref", doc.new_str("#/$defs/node"));
    auto children = doc.new_obj();
    doc.obj_add(children, "type",  doc.new_str("array"));
    doc.obj_add(children, "items", self_ref);
    doc.obj_add(children, "description", doc.new_str(
        "Present on directories only. Empty when the directory is empty or the depth "
        "limit was reached."));

    auto node_props = doc.new_obj();
    add_typed_prop(doc, node_props, "name", "string", "Entry name, not a full path");
    doc.obj_add(node_props, "type", make_node_type());
    doc.obj_add(node_props, "children", children);
    auto node = make_object_schema(doc, node_props, {"name", "type"});

    auto defs = doc.new_obj();
    doc.obj_add(defs, "node", node);

    // The root IS a node; restate its shape rather than $ref-ing the root at itself,
    // which some validators reject.
    auto root_props = doc.new_obj();
    add_typed_prop(doc, root_props, "name", "string", "Name of the root directory");
    doc.obj_add(root_props, "type", make_node_type());
    auto root_children = doc.new_obj();
    doc.obj_add(root_children, "type", doc.new_str("array"));
    auto root_ref = doc.new_obj();
    doc.obj_add(root_ref, "$ref", doc.new_str("#/$defs/node"));
    doc.obj_add(root_children, "items", root_ref);
    doc.obj_add(root_props, "children", root_children);

    auto schema = make_object_schema(doc, root_props, {"name", "type"});
    doc.obj_add(schema, "$defs", defs);
    return schema;
}

static Json::MutableVal make_list_allowed_directories_output(Json::MutableDoc &doc)
{
    auto dir_props = doc.new_obj();
    add_typed_prop(doc, dir_props, "path", "string", "Canonical absolute path");
    add_typed_prop(doc, dir_props, "writable", "boolean",
        "True for read-write roots, false for read-only");

    auto dirs = doc.new_obj();
    doc.obj_add(dirs, "type",  doc.new_str("array"));
    doc.obj_add(dirs, "items", make_object_schema(doc, dir_props, {"path", "writable"}));
    doc.obj_add(dirs, "description", doc.new_str(
        "Allowed roots. Empty means all filesystem access is denied."));

    auto props = doc.new_obj();
    doc.obj_add(props, "directories", dirs);
    return make_object_schema(doc, props, {"directories"});
}

static Json::MutableVal make_grep_files_output(Json::MutableDoc &doc)
{
    auto match_props = doc.new_obj();
    add_typed_prop(doc, match_props, "path", "string", "Absolute path of the file");
    add_typed_prop(doc, match_props, "line", "integer", "1-based line number");
    add_typed_prop(doc, match_props, "text", "string", "The line's contents, without the newline");
    add_typed_prop(doc, match_props, "isMatch", "boolean",
        "True for a matching line, false for a surrounding context line");

    auto matches = doc.new_obj();
    doc.obj_add(matches, "type",  doc.new_str("array"));
    doc.obj_add(matches, "items",
        make_object_schema(doc, match_props, {"path", "line", "text", "isMatch"}));
    doc.obj_add(matches, "description", doc.new_str(
        "Matching lines, plus context lines when contextLines > 0"));

    auto props = doc.new_obj();
    doc.obj_add(props, "matches", matches);
    add_typed_prop(doc, props, "count", "integer",
        "Number of matching lines, excluding context lines");
    add_typed_prop(doc, props, "truncated", "boolean",
        "True when the search stopped at the 'max' cap");
    add_typed_prop(doc, props, "skipped", "integer",
        "Paths skipped because they fall outside the allowed directories");
    return make_object_schema(doc, props, {"matches", "count", "truncated", "skipped"});
}

static Json::MutableVal make_execute_command_output(Json::MutableDoc &doc)
{
    auto props = doc.new_obj();
    add_typed_prop(doc, props, "stdout", "string", "Captured standard output, up to 512 KB");
    add_typed_prop(doc, props, "stderr", "string", "Captured standard error, up to 512 KB");
    add_typed_prop(doc, props, "exitCode", "integer", "Process exit status");
    add_typed_prop(doc, props, "timedOut", "boolean",
        "True when the command was killed at the timeout; exitCode is then not meaningful");
    return make_object_schema(doc, props, {"stdout", "stderr", "exitCode", "timedOut"});
}

// with_output_schemas is false for a 2024-11-05 client. outputSchema is a 2025-06-18
// field, and declaring one is what obliges the server to return conforming
// structuredContent - which that client is not being sent. Advertising the schema while
// withholding the data would be the mismatch, so both are gated on the same flag.
static std::string build_tools_list_json(bool with_output_schemas)
{
    Json::MutableDoc doc;
    auto tools = doc.new_arr();
    // Threaded into every add_tool call below via this lambda so a tool cannot opt out
    // of the gate by accident.
    auto out_schema = [&](Json::MutableVal schema) {
        return with_output_schemas ? schema : Json::MutableVal{};
    };
    (void)out_schema;

    // read_file
    {
        auto props = doc.new_obj();
        add_str_prop(doc, props, "path", "Absolute path to the file");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"path"}));
        doc.arr_append(tools, add_tool(doc, "read_file",
            "Read the complete contents of a file. Returns UTF-8 text, or for a binary "
            "file an embedded resource content block with the bytes base64-encoded in "
            "resource.blob. Maximum 10 MB.", schema, kObserves));
    }

    // read_multiple_files
    {
        auto paths_prop = doc.new_obj();
        doc.obj_add(paths_prop, "type", doc.new_str("array"));
        auto items = doc.new_obj();
        doc.obj_add(items, "type", doc.new_str("string"));
        doc.obj_add(paths_prop, "items", items);
        doc.obj_add(paths_prop, "description", doc.new_str(
            "Array of literal absolute file paths (max 50). Globs are NOT expanded here — "
            "use glob_search or grep_files for globs."));
        auto props = doc.new_obj();
        doc.obj_add(props, "paths", paths_prop);
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"paths"}));
        doc.arr_append(tools, add_tool(doc, "read_multiple_files",
            "Read multiple files simultaneously. Each result is prefixed with its path. "
            "Errors are included inline rather than failing the whole call. Maximum 50 files.",
            schema, kObserves));
    }

    // write_file
    {
        auto props = doc.new_obj();
        add_str_prop(doc, props, "path",    "Absolute path to the file to write");
        add_str_prop(doc, props, "content", "UTF-8 text content to write");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"path", "content"}));
        doc.arr_append(tools, add_tool(doc, "write_file",
            "Create or overwrite a file with the given content. Creates parent directories as needed.",
            schema, kOverwrites));
    }

    // edit_file
    {
        auto edit_item_props = doc.new_obj();
        add_str_prop(doc, edit_item_props, "oldText",
            "Text to find (required). PREFER LITERAL matching (isRegex=false, the default) whenever "
            "you know the exact text to change — literal is safer and self-checking: if the text is "
            "not present verbatim the edit errors instead of changing the wrong place. With "
            "isRegex=true this is an ECMAScript (JavaScript) regex instead. A literal oldText must be "
            "unique at the default limit; include enough surrounding lines that it matches exactly "
            "one place.");
        add_str_prop(doc, edit_item_props, "newText",
            "Replacement text (default: empty string). With isRegex=true, \\1..\\9 OR the "
            "JavaScript-style $1..$9 insert captured groups; \\0, $0, and $& all insert the whole "
            "match (no capture group needed); $$ inserts a literal '$'. Numbered back-references "
            "work ONLY when oldText has that many parenthesized groups. Example (variable text): to "
            "wrap an UNKNOWN line in quotes use oldText \"(.*)\" with newText \"\\1\" (or \"$1\"); "
            "for a KNOWN line, skip regex — use a literal edit with the already-quoted text as "
            "newText. Referencing a group the pattern lacks is an error (replay will NOT silently "
            "insert empty text).");
        add_int_prop(doc, edit_item_props, "limit",
            "Maximum replacements (default 1; 0 = unlimited). With the default of 1 a LITERAL "
            "oldText must match exactly once — an ambiguous oldText that occurs multiple times is "
            "an error (add surrounding context to make it unique, or set limit:0 for all / limit:N "
            "for the first N). Regex is exempt: limit:1 edits the first match.");
        add_bool_prop(doc, edit_item_props, "isRegex",
            "Treat oldText as an ECMAScript (JavaScript) regex pattern (default false). Keep it "
            "false when you know the exact text to change: a LITERAL oldText/newText is simpler, "
            "safer, and idempotent — re-running will not double-apply, and a target that is no "
            "longer present errors instead of mangling other text. Set isRegex=true ONLY when the "
            "target is variable or you need a pattern across many lines (text you do not know "
            "verbatim). In regex mode: parentheses in oldText capture text reused as \\1..\\9 (or "
            "$1..$9) in newText; ^ and $ anchor at every line boundary (multiline) and . does not "
            "cross newlines, so ^(.*)$ matches a whole line. Regex is easy to misjudge — ALWAYS "
            "preview with dryRun=true and check the diff before applying.");
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
        add_bool_prop(doc, props, "dryRun",
            "Preview the result as a unified diff WITHOUT writing the file (default false). "
            "Use this FIRST for any regex edit: regex is easy to get subtly wrong, and a bad "
            "pattern can silently mangle the whole file. Run with dryRun=true, read the diff, "
            "confirm it changes exactly what you intend, THEN re-issue the identical call with "
            "dryRun=false to apply it. Edits overwrite in place and cannot be auto-undone.");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"path", "edits"}));
        doc.arr_append(tools, add_tool(doc, "edit_file",
            "Apply text edits to a file. Supports literal and ECMAScript (JavaScript) regex matching, "
            "back-references, case-insensitive mode, and configurable replacement limits. "
            "Writes atomically. Extended beyond standard MCP edit_file. "
            "Prefer literal matching (isRegex=false) for known/specific text — it is safer and "
            "idempotent; reserve isRegex for variable text or patterns spanning many lines. "
            "IMPORTANT: when using isRegex, preview with dryRun=true and verify the returned diff "
            "before applying — a wrong regex can destroy content, and the change is not auto-undoable.",
            schema, kMutates));
    }

    // edit_files (extended — multi-file via literal paths and/or glob patterns)
    {
        auto edit_item_props = doc.new_obj();
        add_str_prop(doc, edit_item_props, "oldText",
            "Text to find (required). PREFER LITERAL matching (isRegex=false, the default) whenever "
            "you know the exact text to change — literal is safer and self-checking: if the text is "
            "not present verbatim the edit errors instead of changing the wrong place. With "
            "isRegex=true this is an ECMAScript (JavaScript) regex instead. A literal oldText must be "
            "unique at the default limit; include enough surrounding lines that it matches exactly "
            "one place.");
        add_str_prop(doc, edit_item_props, "newText",
            "Replacement text (default: empty string). With isRegex=true, \\1..\\9 OR the "
            "JavaScript-style $1..$9 insert captured groups; \\0, $0, and $& all insert the whole "
            "match (no capture group needed); $$ inserts a literal '$'. Numbered back-references "
            "work ONLY when oldText has that many parenthesized groups. Example (variable text): to "
            "wrap an UNKNOWN line in quotes use oldText \"(.*)\" with newText \"\\1\" (or \"$1\"); "
            "for a KNOWN line, skip regex — use a literal edit with the already-quoted text as "
            "newText. Referencing a group the pattern lacks is an error (replay will NOT silently "
            "insert empty text).");
        add_int_prop(doc, edit_item_props, "limit",
            "Maximum replacements per file (default 1; 0 = unlimited). With the default of 1 a "
            "LITERAL oldText must match exactly once in each file — an ambiguous oldText that "
            "occurs multiple times is an error (add surrounding context to make it unique, or set "
            "limit:0 for all / limit:N for the first N). Regex is exempt: limit:1 edits the first "
            "match.");
        add_bool_prop(doc, edit_item_props, "isRegex",
            "Treat oldText as an ECMAScript (JavaScript) regex pattern (default false). Keep it "
            "false when you know the exact text to change: a LITERAL oldText/newText is simpler, "
            "safer, and idempotent — re-running will not double-apply, and a target that is no "
            "longer present errors instead of mangling other text. Set isRegex=true ONLY when the "
            "target is variable or you need a pattern across many lines (text you do not know "
            "verbatim). In regex mode: parentheses in oldText capture text reused as \\1..\\9 (or "
            "$1..$9) in newText; ^ and $ anchor at every line boundary (multiline) and . does not "
            "cross newlines, so ^(.*)$ matches a whole line. Regex is easy to misjudge — ALWAYS "
            "preview with dryRun=true and check the diff before applying.");
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
        add_bool_prop(doc, props, "dryRun",
            "Preview the result of every resolved file as a per-file unified diff WITHOUT writing "
            "(default false). Strongly recommended before applying, ESPECIALLY here: this tool can "
            "rewrite many files at once (globs, limit=0), so one wrong regex corrupts them all in a "
            "single call. Run with dryRun=true, inspect each file's diff, confirm they are exactly "
            "what you intend, THEN re-issue the identical call with dryRun=false. Not auto-undoable.");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"paths", "edits"}));
        doc.arr_append(tools, add_tool(doc, "edit_files",
            "[Extended] Apply edits to one or more files specified as literal paths and/or glob patterns. "
            "Glob patterns (e.g. /src/**/*.cpp) expand to all matching files at runtime. "
            "Supports all edit_file options. Returns per-file results in a single response. "
            "Prefer literal matching (isRegex=false) for known/specific text — it is safer and "
            "idempotent; reserve isRegex for variable text or patterns spanning many lines. "
            "IMPORTANT: this edits MANY files at once and is destructive — for regex edits (and any "
            "limit=0 or glob edit) run with dryRun=true first and verify every per-file diff before "
            "re-issuing with dryRun=false. The change cannot be auto-undone.",
            schema, kMutates));
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
            "the command exits non-zero or times out."
            "macOS kernel sandbox enforces filesystem access limits on the child process - "
            "making shell execution safer than soft path-checking.",
            schema, kRunsCommands,
            out_schema(make_execute_command_output(doc))));
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
            schema, kCreates));
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
            schema, kObserves,
            out_schema(make_list_directory_output(doc))));
    }

    // directory_tree
    {
        auto props = doc.new_obj();
        add_str_prop(doc, props, "path", "Absolute path to the root directory");
        add_int_prop(doc, props, "depth",
            "Maximum recursion depth. Omit for unlimited (standard MCP). "
            "0 = root node only (no children), 1 = root + immediate children, "
            "N = N levels deep. Same semantics as find -maxdepth.");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"path"}));
        doc.arr_append(tools, add_tool(doc, "directory_tree",
            "Recursively list a directory as a JSON tree. Each node has name, type, and children. "
            "Returns the full tree by default (no depth limit). "
            "[Extended] Optional depth param: 0 = root only, N = N levels (find -maxdepth semantics).",
            schema, kObserves,
            out_schema(make_directory_tree_output(doc))));
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
            "Move or rename a file or directory.", schema, kMutates));
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
            "Delete a file or directory (recursively). No confirmation requested.", schema, kRemoves));
    }

    // search_files — standard MCP: case-insensitive filename substring match
    {
        auto excl_items = doc.new_obj();
        doc.obj_add(excl_items, "type", doc.new_str("string"));
        auto excl_prop = doc.new_obj();
        doc.obj_add(excl_prop, "type", doc.new_str("array"));
        doc.obj_add(excl_prop, "items", excl_items);
        doc.obj_add(excl_prop, "description",
            doc.new_str("Glob patterns to exclude from the search"));
        auto props = doc.new_obj();
        add_str_prop(doc, props, "directory",
            "Absolute root directory to search recursively (required)");
        add_str_prop(doc, props, "nameContains",
            "Literal substring to match against file and directory names (case-insensitive; "
            "NOT a glob or regex). Required. For glob matching use glob_search.");
        doc.obj_add(props, "excludeGlobs", excl_prop);
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"directory", "nameContains"}));
        doc.arr_append(tools, add_tool(doc, "search_files",
            "Find files and directories whose NAME contains a literal substring "
            "(case-insensitive; not a glob or regex), searching recursively under "
            "'directory'. Returns a match count followed by one resource_link per hit; "
            "the same paths are in structuredContent.matches. To match by glob use "
            "glob_search; to search file contents use grep_files.",
            schema, kObserves, out_schema(make_matches_schema(doc, /*with_truncated*/ false))));
    }

    // grep_files — [ext] content search (grep-style)
    {
        auto excl_items = doc.new_obj();
        doc.obj_add(excl_items, "type", doc.new_str("string"));
        auto excl_prop = doc.new_obj();
        doc.obj_add(excl_prop, "type", doc.new_str("array"));
        doc.obj_add(excl_prop, "items", excl_items);
        doc.obj_add(excl_prop, "description",
            doc.new_str("Glob patterns to exclude from the search (honored in every mode)."));
        auto globs_items = doc.new_obj();
        doc.obj_add(globs_items, "type", doc.new_str("string"));
        auto globs_prop = doc.new_obj();
        doc.obj_add(globs_prop, "type", doc.new_str("array"));
        doc.obj_add(globs_prop, "items", globs_items);
        doc.obj_add(globs_prop, "description",
            doc.new_str("File globs that filter which files are searched (e.g. **/*.swift). "
                        "A relative glob is anchored to 'directory' (or, if 'directory' is "
                        "omitted, to the project directory) — it is NOT relative to the "
                        "process working directory. Absolute globs (starting with /) are "
                        "used as-is. Omit to search every file under 'directory'."));
        auto props = doc.new_obj();
        add_str_prop(doc, props, "regex",
            "ECMAScript (JavaScript) regex searched in file CONTENTS (required). Supports "
            "\\d \\w \\s, etc. For a literal substring, escape regex metacharacters (e.g. \\* \\. \\+).");
        add_str_prop(doc, props, "directory",
            "Absolute path of the directory to search, walked recursively. Pass this "
            "whenever you want to limit the search to a specific directory: if you omit it, "
            "the search falls back to the whole project directory (the first allowed "
            "directory) and any relative 'globs' are anchored there, not where you intended. "
            "Required unless every entry in 'globs' is an absolute path.");
        doc.obj_add(props, "globs",        globs_prop);
        doc.obj_add(props, "excludeGlobs", excl_prop);
        add_bool_prop(doc, props, "caseInsensitive",
            "Case-insensitive matching, like grep -i (default false)");
        add_int_prop(doc, props, "contextLines",
            "Lines of context before and after each match, like grep -C (default 0, max 50)");
        add_int_prop(doc, props, "maxResults",
            "Maximum total matches to return across all files (default 500, max 10000)");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"regex"}));
        doc.arr_append(tools, add_tool(doc, "grep_files",
            "[Extended] Search file CONTENTS for an ECMAScript (JavaScript) regex (grep-style). "
            "Returns file:line:content matches. Scope the search with 'directory' (the directory "
            "to walk recursively) and/or 'globs' (file filters like **/*.swift); narrow with "
            "'excludeGlobs'. To search inside one directory, set 'directory' to it — do not rely "
            "on a relative glob alone, since a relative glob is anchored to 'directory' (or the "
            "project directory when 'directory' is omitted). "
            "Example: {\"regex\": \"TODO\", \"directory\": \"/src/app\", \"globs\": [\"**/*.swift\"]}. "
            "To find files by NAME use glob_search (by glob) or search_files (by name substring), "
            "not this tool. Binary files are skipped.", schema, kObserves,
            out_schema(make_grep_files_output(doc))));
    }

    // get_file_info
    {
        auto props = doc.new_obj();
        add_str_prop(doc, props, "path", "Absolute path to a file or directory");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"path"}));
        doc.arr_append(tools, add_tool(doc, "get_file_info",
            "Get metadata for a file or directory: type, size, timestamps, and permissions.",
            schema, kObserves, out_schema(make_get_file_info_output(doc))));
    }

    // list_allowed_directories
    {
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", doc.new_obj());
        doc.arr_append(tools, add_tool(doc, "list_allowed_directories",
            "List the directories this MCP server is allowed to access, "
            "with their access mode (read-only or read-write).", schema, kObserves,
            out_schema(make_list_allowed_directories_output(doc))));
    }

    // glob_search (extended)
    {
        auto globs_items = doc.new_obj();
        doc.obj_add(globs_items, "type", doc.new_str("string"));
        auto globs_prop = doc.new_obj();
        doc.obj_add(globs_prop, "type", doc.new_str("array"));
        doc.obj_add(globs_prop, "items", globs_items);
        doc.obj_add(globs_prop, "description",
            doc.new_str("Glob patterns relative to 'directory' (e.g. **/*.swift, src/*.{cpp,h})"));
        auto excl_items = doc.new_obj();
        doc.obj_add(excl_items, "type", doc.new_str("string"));
        auto excl_prop = doc.new_obj();
        doc.obj_add(excl_prop, "type", doc.new_str("array"));
        doc.obj_add(excl_prop, "items", excl_items);
        doc.obj_add(excl_prop, "description",
            doc.new_str("Glob patterns to exclude from the results"));
        auto props = doc.new_obj();
        add_str_prop(doc, props, "directory", "Absolute root directory to search");
        doc.obj_add(props, "globs",        globs_prop);
        doc.obj_add(props, "excludeGlobs", excl_prop);
        add_int_prop(doc, props, "max",
            "Maximum results (default 1000). 0 or omitted means the 1000 default, not "
            "unlimited; raise it explicitly to go past 1000. structuredContent.truncated "
            "reports when the cap was reached.");
        auto schema = doc.new_obj();
        doc.obj_add(schema, "type", doc.new_str("object"));
        doc.obj_add(schema, "properties", props);
        doc.obj_add(schema, "required", make_req(doc, {"directory", "globs"}));
        doc.arr_append(tools, add_tool(doc, "glob_search",
            "[Extended] Find files by filename GLOB using replay's glob engine. "
            "Returns matching files only (not directories). Supports "
            "** (recursive), ? (single char), {a,b} (alternation). "
            "Globs are relative to 'directory'. Returns a match count followed by one "
            "resource_link per hit; the same paths are in structuredContent.matches, "
            "with structuredContent.truncated set when the 'max' cap was reached. "
            "To search file CONTENTS use grep_files; "
            "to match a literal name substring use search_files.",
            schema, kObserves, out_schema(make_matches_schema(doc, /*with_truncated*/ true))));
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
        ActionContext ac = {{}, -1, "null"};
        PrintMCPError(context, &ac, -32700, "Parse error");
        return;
    }

    Json::Val root = doc.root();
    if (!root.is_obj())
    {
        ActionContext ac = {{}, -1, "null"};
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
        ActionContext ac = {{}, -1, request_id};
        PrintMCPError(context, &ac, -32600, "Invalid request: missing method");
        return;
    }
    std::string_view method = *method_sv;

    ActionContext ac = {{}, -1, request_id};

    if (method == "initialize")
    {
        initialized = true;
        Json::MutableDoc resp;
        auto result = resp.new_obj();
        // Negotiate rather than assert: echo the client's requested revision when it
        // is one we speak, otherwise answer with our latest and let the client decide.
        // Falling back to the latest rather than the oldest is what keeps newer
        // clients whole - a client on a revision we do not list that was answered
        // "2024-11-05" would be entitled to decode tools with the older type and drop
        // `annotations`, which is how a host silently loses the read-only/mutating
        // distinction its permission prompts are built from.
        //
        // Stay tolerant here: a missing protocolVersion, a non-string one, and an
        // unknown revision all fall through to the default without erroring. Cadabra's
        // launch probe drops any server whose handshake fails, so a hard error would
        // not degrade replay's feature set - it would remove replay from the app.
        std::string_view negotiated = kProtocolVersion;
        if (auto requested = root.obj_get("params").obj_get("protocolVersion").get_str())
        {
            for (auto supported : kSupportedProtocolVersions)
            {
                if (*requested == supported)
                {
                    negotiated = supported;
                    break;
                }
            }
        }
        // Record what was agreed, so the result builders can honour it. Everything
        // replay supports above 2024-11-05 has the 2025-06-18 result surface, so the
        // question is just whether the client landed on the oldest revision.
        g_structuredOutputNegotiated.store(negotiated != std::string_view("2024-11-05"),
                                           std::memory_order_relaxed);

        resp.obj_add(result, "protocolVersion", resp.new_str(negotiated));
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
        // Two cached variants rather than one: which is correct depends on the
        // negotiated revision, and building it per request would re-serialize 16 tool
        // schemas on every call.
        static const std::string kToolsJsonModern = build_tools_list_json(true);
        static const std::string kToolsJsonLegacy = build_tools_list_json(false);
        const std::string &kToolsJson = structured_output_negotiated()
                                            ? kToolsJsonModern : kToolsJsonLegacy;
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

        AsyncDispatch([captured_id   = std::move(captured_id),
                       captured_tool = std::move(captured_tool),
                       shared_doc    = std::move(shared_doc),
                       context, opts]() {
            ActionContext ac;
            ac.index        = -1;
            ac.mcpRequestID = captured_id;

            Json::Val req_params = shared_doc->root().obj_get("params");
            Json::Val tool_args  = req_params.obj_get("arguments");

            dispatch_mcp_tool(captured_tool, tool_args, context, &ac, opts);
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

    // Announce the whole set, not one constant: the banner is the only place an
    // operator can see what replay will actually agree to, and the default alone
    // hides the fact that older clients are still served.
    std::string supportedList;
    for (auto supported : kSupportedProtocolVersions)
    {
        if (!supportedList.empty())
            supportedList += ", ";
        supportedList.append(supported);
    }
    fprintf(stderr, "replay-mcp: starting MCP server (protocol %s; supported: %s)\n",
            kProtocolVersion, supportedList.c_str());
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
