#pragma once

#include <string>
#include <vector>

#include "ReplayAction.h"

struct MCPAllowedDir {
    std::string path;   // canonical absolute path
    bool writable;      // true = read+write; false = read-only
};

struct MCPServerOptions {
    std::vector<MCPAllowedDir> allowedDirs;
};

// JSON-RPC result/error builders — implemented in MCPServer.mm.
// Called from action files via the PrintMCP* helpers in ReplayActionPrivate.h.
std::string MakeMCPTextResult(const std::string &id_raw, std::string text);
std::string MakeMCPBlobResult(const std::string &id_raw, std::string base64Data,
                               std::string mimeType);
std::string MakeMCPError(const std::string &id_raw, int code, std::string message);
std::string MakeMCPMultiTextResult(const std::string &id_raw,
                                    const std::vector<std::string> &texts);
// Builds a tools/call result for execute_command: stdout + optional stderr content item,
// isError=true when exit_code != 0 or timed_out.
std::string MakeMCPExecuteResult(const std::string &id_raw, const MCPExecuteResult &r);

// Run the MCP server over stdio (JSON-RPC 2.0 / MCP protocol).
// context must have mcpServer=true and outputSerializer set.
// Blocks until stdin closes (EOF). Returns EXIT_SUCCESS on clean exit.
int RunMCPServer(ReplayContext *context, const MCPServerOptions &opts);
