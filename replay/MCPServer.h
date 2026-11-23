#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include "ReplayAction.h"

struct MCPAllowedDir {
    std::string path;   // canonical absolute path
    bool writable;      // true = read+write; false = read-only
};

struct MCPServerOptions {
    std::vector<MCPAllowedDir> allowedDirs;
    bool kernelSandbox = true;  // false: no Seatbelt sandbox (--no-sandbox, or no allow flags)
};

namespace Json { class MutableDoc; }

// The JSON text of a reply or of its structured content. A string that is not valid
// UTF-8 (command output or a file name in another encoding) makes the plain writer
// fail; then each invalid sequence is written as U+FFFD and all non-ASCII is escaped,
// so the text stays valid JSON. Empty only when even that fails.
std::string MCPJsonText(const Json::MutableDoc &doc);

// The most read_file and read_multiple_files return of one file, as their descriptions say.
constexpr std::size_t kMCPMaxFileSize = 10u * 1024u * 1024u;

// JSON-RPC result/error builders, implemented in MCPServer.cpp.
// Called from action files via the PrintMCP* helpers in ReplayActionPrivate.h.
std::string MakeMCPTextResult(const std::string &id_raw, std::string text);
// Binary contents as an embedded resource content block. filePath is the absolute
// path the bytes came from; it becomes the resource's file:// URI, which is what
// identifies an embedded resource. (There is no "blob" content type in MCP - `blob`
// is the base64 field inside a resource.)
std::string MakeMCPBlobResult(const std::string &id_raw, const std::string &filePath,
                               std::string base64Data, std::string mimeType);
std::string MakeMCPError(const std::string &id_raw, int code, std::string message);
std::string MakeMCPMultiTextResult(const std::string &id_raw,
                                    const std::vector<std::string> &texts);

// A text content block plus `structuredContent` (2025-06-18+). structuredJson must be
// a serialized JSON *object*, embedded verbatim; pass an empty string to omit it.
// The human-readable text block is kept rather than replaced by the serialized JSON:
// see the note on structured output in MCPServer.cpp.
std::string MakeMCPStructuredResult(const std::string &id_raw, std::string text,
                                     std::string structuredJson);

// A short summary text block followed by one `resource_link` block per path, plus
// `structuredContent`. For the tools that answer with a list of files: the links are
// the machine-readable form, the summary carries the count and any truncation notice.
std::string MakeMCPResourceLinkResult(const std::string &id_raw, std::string summaryText,
                                       const std::vector<std::string> &paths,
                                       std::string structuredJson);
// Builds a tools/call result for execute_command: stdout + optional stderr content item,
// isError=true when exit_code != 0 or timed_out.
std::string MakeMCPExecuteResult(const std::string &id_raw, const MCPExecuteResult &r);

// Run the MCP server over stdio (JSON-RPC 2.0 / MCP protocol).
// context must have mcpServer=true and outputSerializer set.
// Blocks until stdin closes (EOF). Returns EXIT_SUCCESS on clean exit.
int RunMCPServer(ReplayContext *context, const MCPServerOptions &opts);
