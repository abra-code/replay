#include "ReplayAction.h"
#include "ReplayActionPrivate.h"
#include "ChildProcess.h"
#include <string>
#include <vector>

static constexpr size_t kMCPMaxCommandOutput = 512u * 1024u; // 512 KB per stream
static constexpr int    kMCPDefaultTimeout    = 30;          // seconds

MCPExecuteResult
ExcecuteToolMCPCore(const std::string &toolPath, const std::vector<std::string> &arguments,
                    const std::string &workingDir, int timeoutSeconds)
{
    ChildProcess::Options opts;
    opts.argv.reserve(arguments.size() + 1);
    opts.argv.push_back(toolPath);
    for (const auto &arg : arguments)
        opts.argv.push_back(arg);
    opts.workingDir     = workingDir;
    opts.captureStdout  = true;
    opts.captureStderr  = true;
    opts.maxOutputBytes = kMCPMaxCommandOutput;
    opts.timeoutSeconds = timeoutSeconds;

    ChildProcess::Result r = ChildProcess::Run(opts);

    MCPExecuteResult res;
    res.launched     = r.launched;
    res.timed_out    = r.timed_out;
    res.exit_code    = r.exit_code;
    res.stdout_text  = std::move(r.stdout_text);
    res.stderr_text  = std::move(r.stderr_text);
    res.launch_error = std::move(r.launch_error);
    return res;
}

bool
ExcecuteTool(const std::string &toolPath, const std::vector<std::string> &arguments, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
		return false;

    // MCP mode: capture stdout/stderr and return them as a JSON-RPC response.
    if (context->mcpServer)
    {
        std::string workingDir = actionContext->settings.string_value("workingDirectory").value_or("");
        int timeoutSec = (int)actionContext->settings.int_value("timeout", kMCPDefaultTimeout);

        MCPExecuteResult r = ExcecuteToolMCPCore(toolPath, arguments, workingDir, timeoutSec);
        if (!r.launched)
        {
            PrintMCPError(context, actionContext, -32603, r.launch_error);
            return false;
        }
        PrintMCPExecuteResult(context, actionContext, r);
        return r.exit_code == 0;
    }

	bool useStdOut = actionContext->settings.bool_value("stdout", true);

	if(context->verbose || context->dryRun)
	{
		const char *settingsCStr = useStdOut ? "" : " stdout=false";
		std::string stdoutStr = std::string("[execute") + settingsCStr + "]\t" + toolPath;
		for(const auto &arg : arguments)
			{ stdoutStr += "\t"; stdoutStr += arg; }
		stdoutStr += "\n";
		PrintToStdOut(context, std::move(stdoutStr), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	// tool execution is expected to print two strings to stdout
	// track if the second print happened, else inform output serializer of no output
	actionContext->index++;
	bool secondStringPrinted = false;

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
        ChildProcess::Options opts;
        opts.argv.reserve(arguments.size() + 1);
        opts.argv.push_back(toolPath);
        for (const auto &arg : arguments)
            opts.argv.push_back(arg);
        opts.captureStdout = true;
        opts.captureStderr = true;

        ChildProcess::Result r = ChildProcess::Run(opts);

        if (!r.launched)
        {
            std::string errMsg = std::string("error: failed to execute \"") + toolPath + "\". " + r.launch_error + "\n";
            context->lastError.set(errMsg, errno);
            PrintToStdErr(context, std::move(errMsg));
        }
        else
        {
            isSuccessful = true;

            if (r.exit_code != EXIT_SUCCESS)
            {
                if (!r.stderr_text.empty())
                    PrintToStdErr(context, r.stderr_text);
                std::string toolErrStr = std::string("error: failed to execute \"") + toolPath + "\". Error: " + std::to_string(r.exit_code) + "\n";
                context->lastError.set(toolErrStr, r.exit_code);
                PrintToStdErr(context, std::move(toolErrStr));
            }

            if (useStdOut && !r.stdout_text.empty())
            {
                PrintToStdOut(context, std::move(r.stdout_text), actionContext->index);
                secondStringPrinted = true;
            }
        }
	}

	if(!secondStringPrinted)
		ActionWithNoOutput(context, actionContext->index);

	return isSuccessful;
}

bool
Echo(const std::string &text, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
		return false;

	bool addNewline = actionContext->settings.bool_value("newline", true);

	if(context->verbose || context->dryRun)
	{
		bool useRaw = actionContext->settings.bool_value("raw", false);
		const char *rawCStr = useRaw ? " raw=true" : "";
		const char *newlineCStr = addNewline ? "" : " newline=false";
		std::string desc = std::string("[echo") + rawCStr + newlineCStr + "]\t" + text + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	// echo is expected to print two strings to stdout (verbose status and actual string)
	actionContext->index++;

	if(!context->dryRun)
	{
		if(addNewline)
			PrintToStdOut(context, text + "\n", actionContext->index);
		else
			PrintToStdOut(context, text, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	return true;
}
