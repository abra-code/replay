#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#include <string>
#include <vector>
#include <signal.h>

static constexpr size_t kMCPMaxCommandOutput = 512u * 1024u; // 512 KB per stream
static constexpr int    kMCPDefaultTimeout    = 30;           // seconds

MCPExecuteResult
ExcecuteToolMCPCore(const std::string &toolPath, const std::vector<std::string> &arguments,
                    const std::string &workingDir, int timeoutSeconds)
{
    MCPExecuteResult res;

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@(toolPath.c_str())];
    NSMutableArray *nsArgs = [NSMutableArray arrayWithCapacity:arguments.size()];
    for(const auto &arg : arguments)
        [nsArgs addObject:@(arg.c_str())];
    [task setArguments:nsArgs];
    if (!workingDir.empty())
        [task setCurrentDirectoryPath:@(workingDir.c_str())];

    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    NSPipe *inPipe  = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:errPipe];
    [task setStandardInput:inPipe];

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError])
    {
        NSString *desc = [launchError localizedDescription];
        res.launch_error = std::string("Failed to launch ")
            + toolPath + ": "
            + (desc != nil ? [desc UTF8String] : "unknown");
        return res;
    }
    res.launched = true;

    // Close stdin write end immediately — child gets EOF on first read attempt.
    [[inPipe fileHandleForWriting] closeFile];

    // Drain stdout and stderr concurrently: if either pipe buffer fills while
    // the parent reads the other, the child deadlocks. Two GCD tasks avoid that.
    __block NSData *stdoutData = nil;
    __block NSData *stdErrData = nil;
    dispatch_group_t readGroup = dispatch_group_create();
    dispatch_queue_t ioQueue   = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

    dispatch_group_async(readGroup, ioQueue, ^{
        NSError *e = nil;
        stdoutData = [[outPipe fileHandleForReading] readDataToEndOfFileAndReturnError:&e];
    });
    dispatch_group_async(readGroup, ioQueue, ^{
        NSError *e = nil;
        stdErrData = [[errPipe fileHandleForReading] readDataToEndOfFileAndReturnError:&e];
    });

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW,
                                              (int64_t)timeoutSeconds * NSEC_PER_SEC);
    if (dispatch_group_wait(readGroup, deadline) != 0)
    {
        res.timed_out = true;
        pid_t pid = [task processIdentifier];
        [task terminate]; // SIGTERM — gives the process a chance to clean up
        dispatch_time_t grace = dispatch_time(DISPATCH_TIME_NOW, 3LL * NSEC_PER_SEC);
        if (dispatch_group_wait(readGroup, grace) != 0)
        {
            if ([task isRunning] != NO)
                kill(pid, SIGKILL);
            dispatch_group_wait(readGroup, DISPATCH_TIME_FOREVER);
        }
    }

    [task waitUntilExit];
    res.exit_code = [task terminationStatus];

    auto trimData = [](NSData *data) -> std::string
    {
        if (data == nil || data.length == 0)
            return {};
        size_t len = std::min((size_t)data.length, kMCPMaxCommandOutput);
        std::string s(static_cast<const char *>(data.bytes), len);
        if ((size_t)data.length > kMCPMaxCommandOutput)
            s += "\n[output truncated at 512 KB]";
        return s;
    };

    res.stdout_text = trimData(stdoutData);
    res.stderr_text = trimData(stdErrData);
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
        NSString *workDirNS = actionContext->settings[@"workingDirectory"];
        std::string workingDir = workDirNS != nil ? [workDirNS UTF8String] : "";
        NSNumber *timeoutNum = actionContext->settings[@"timeout"];
        int timeoutSec = timeoutNum != nil ? (int)[timeoutNum intValue] : kMCPDefaultTimeout;

        MCPExecuteResult r = ExcecuteToolMCPCore(toolPath, arguments, workingDir, timeoutSec);
        if (!r.launched)
        {
            PrintMCPError(context, actionContext, -32603, r.launch_error);
            return false;
        }
        PrintMCPExecuteResult(context, actionContext, r);
        return r.exit_code == 0;
    }

	NSNumber *useStdOutNum = actionContext->settings[@"stdout"];
	bool useStdOut = true;
	if([useStdOutNum isKindOfClass:[NSNumber class]])
		useStdOut = [useStdOutNum boolValue];

	if(context->verbose || context->dryRun)
	{
		const char *settingsCStr = (useStdOutNum == nil) ? "" : (useStdOut ? " stdout=true" : " stdout=false");
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
		NSTask *task = [[NSTask alloc] init];
		[task setLaunchPath:@(toolPath.c_str())];
		NSMutableArray *nsArgs = [NSMutableArray arrayWithCapacity:arguments.size()];
		for(const auto &arg : arguments)
			[nsArgs addObject:@(arg.c_str())];
		[task setArguments:nsArgs];

		NSPipe *stdErrPipe = [NSPipe pipe];
		[task setStandardError:stdErrPipe];

		[task setTerminationHandler: ^(NSTask *task) {
			int toolStatus = [task terminationStatus];
			if(toolStatus != EXIT_SUCCESS)
			{
				NSError *dataError = nil;
				NSFileHandle *stdOutFileHandle = [stdErrPipe fileHandleForReading];
				NSData *stdErrData = [stdOutFileHandle readDataToEndOfFileAndReturnError:&dataError];
				if((stdErrData != nil) && (stdErrData.length > 0))
				{
					PrintToStdErr(context, std::string((const char *)[stdErrData bytes], (size_t)[stdErrData length]));
				}

				std::string toolErrStr = std::string("error: failed to execute \"") + toolPath + "\". Error: " + std::to_string(toolStatus) + "\n";
				context->lastError.set(toolErrStr, toolStatus);
				PrintToStdErr(context, std::move(toolErrStr));
			}
		}];

		NSPipe *stdOutPipe = [NSPipe pipe];
		[task setStandardOutput:stdOutPipe];

		NSPipe *stdInPipe = [NSPipe pipe];
		[task setStandardInput:stdInPipe];

		NSError *operationError = nil;
		isSuccessful = (bool)[task launchAndReturnError:&operationError];
		if(isSuccessful)
		{
			NSFileHandle *stdOutFileHandle = [stdOutPipe fileHandleForReading];
			NSData *stdOutData = [stdOutFileHandle readDataToEndOfFileAndReturnError:&operationError];
			if(stdOutData != nil)
			{
				if(useStdOut)
				{
					PrintToStdOut(context, std::string((const char *)[stdOutData bytes], (size_t)[stdOutData length]), actionContext->index);
					secondStringPrinted = true;
				}
			}
			else
			{
				isSuccessful = false;
			}
		}

		if (!isSuccessful)
		{
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];
			std::string launchErrStr = std::string("error: failed to execute \"") + toolPath + "\". Error: " + ([errorDesc UTF8String] ?: "unknown") + "\n";
			context->lastError.set(launchErrStr, operationError ? (int)[operationError code] : 1);
			PrintToStdErr(context, std::move(launchErrStr));
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

	bool addNewline = true;
	id newlineVal = actionContext->settings[@"newline"];
	if([newlineVal isKindOfClass:[NSNumber class]])
		addNewline = [newlineVal boolValue];

	if(context->verbose || context->dryRun)
	{
		id useRawText = actionContext->settings[@"raw"];
		const char *rawCStr = ([useRawText isKindOfClass:[NSNumber class]]) ? ([useRawText boolValue] ? " raw=true" : " raw=false") : "";
		const char *newlineCStr = (newlineVal != nil) ? (addNewline ? " newline=true" : " newline=false") : "";
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
