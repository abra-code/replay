#pragma once
// Shared inline output helpers for action implementation files.
// Include only in action .mm/.cpp files — not in public headers.

#include "ReplayAction.h"
#include "MCPServer.h"
#include "OutputSerializer.h"
#include <cassert>
#include <string>
#include <vector>

#include <optional>
std::optional<std::string> ExpandEnvVars(const char *str, ReplayContext *context);

static inline void PrintToStdOut(ReplayContext *context, std::string str, intptr_t actionIndex)
{
    assert(context->outputSerializer != nullptr);
    context->outputSerializer->scheduleString(
        std::move(str),
        context->orderedOutput ? (int64_t)actionIndex : -1
    );
}

static inline void PrintToStdErr(ReplayContext *context, std::string str)
{
    assert(context->outputSerializer != nullptr);
    context->outputSerializer->scheduleErrorString(std::move(str));
}

static inline void ActionWithNoOutput(ReplayContext *context, intptr_t actionIndex)
{
    if(context->orderedOutput)
    {
        assert(context->outputSerializer != nullptr);
        assert(actionIndex >= 0);
        context->outputSerializer->scheduleNoOutput((int64_t)actionIndex);
    }
}

// MCP output helpers — write a JSON-RPC response through OutputSerializer (unordered).
// Only call these when context->mcpServer is true.

static inline void PrintMCPTextResult(ReplayContext *context, ActionContext *actionContext,
                                       std::string text)
{
    assert(context->mcpServer);
    std::string response = MakeMCPTextResult(actionContext->mcpRequestID, std::move(text));
    context->outputSerializer->scheduleString(std::move(response), -1);
}

static inline void PrintMCPBlobResult(ReplayContext *context, ActionContext *actionContext,
                                       std::string base64Data, std::string mimeType)
{
    assert(context->mcpServer);
    std::string response = MakeMCPBlobResult(actionContext->mcpRequestID,
                                              std::move(base64Data), std::move(mimeType));
    context->outputSerializer->scheduleString(std::move(response), -1);
}

static inline void PrintMCPError(ReplayContext *context, ActionContext *actionContext,
                                  int code, std::string message)
{
    assert(context->mcpServer);
    std::string response = MakeMCPError(actionContext->mcpRequestID, code, std::move(message));
    context->outputSerializer->scheduleString(std::move(response), -1);
}

static inline void PrintMCPMultiTextResult(ReplayContext *context, ActionContext *actionContext,
                                            const std::vector<std::string> &texts)
{
    assert(context->mcpServer);
    std::string response = MakeMCPMultiTextResult(actionContext->mcpRequestID, texts);
    context->outputSerializer->scheduleString(std::move(response), -1);
}

static inline void PrintMCPExecuteResult(ReplayContext *context, ActionContext *actionContext,
                                          const MCPExecuteResult &r)
{
    assert(context->mcpServer);
    std::string response = MakeMCPExecuteResult(actionContext->mcpRequestID, r);
    context->outputSerializer->scheduleString(std::move(response), -1);
}
