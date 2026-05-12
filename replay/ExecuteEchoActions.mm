#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#include <string>

bool
ExcecuteTool(NSString *toolPath, NSArray<NSString*> *arguments, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	NSNumber *useStdOutNum = actionContext->settings[@"stdout"];
	bool useStdOut = true;
	if([useStdOutNum isKindOfClass:[NSNumber class]])
		useStdOut = [useStdOutNum boolValue];

	if(context->verbose || context->dryRun)
	{
		const char *settingsCStr = (useStdOutNum == nil) ? "" : (useStdOut ? " stdout=true" : " stdout=false");
		std::string stdoutStr = std::string("[execute") + settingsCStr + "]\t" + [toolPath UTF8String];
		for(NSString *arg in arguments)
			{ stdoutStr += "\t"; stdoutStr += [arg UTF8String]; }
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
		[task setLaunchPath:toolPath];
		[task setArguments:arguments];

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

				std::string toolErrDesc = std::string([toolPath UTF8String]) + " returned error " + std::to_string(toolStatus);
				NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @(toolErrDesc.c_str()) };
				NSError *taskError = [NSError errorWithDomain:NSPOSIXErrorDomain code:toolStatus userInfo:userInfo];
				context->lastError.error = taskError;
				PrintToStdErr(context, std::string("error: failed to execute \"") + [toolPath UTF8String] + "\". Error: " + std::to_string(toolStatus) + "\n");
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
			context->lastError.error = operationError;
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];
			PrintToStdErr(context, std::string("error: failed to execute \"") + [toolPath UTF8String] + "\". Error: " + ([errorDesc UTF8String] ?: "unknown") + "\n");
		}
	}

	if(!secondStringPrinted)
		ActionWithNoOutput(context, actionContext->index);

	return isSuccessful;
}

bool
Echo(NSString *text, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	bool addNewline = true;
	id newlineVal = actionContext->settings[@"newline"];
	if([newlineVal isKindOfClass:[NSNumber class]])
		addNewline = [newlineVal boolValue];

	if(text == nil)
		text = @"";

	if(context->verbose || context->dryRun)
	{
		id useRawText = actionContext->settings[@"raw"];
		const char *rawCStr = ([useRawText isKindOfClass:[NSNumber class]]) ? ([useRawText boolValue] ? " raw=true" : " raw=false") : "";
		const char *newlineCStr = (newlineVal != nil) ? (addNewline ? " newline=true" : " newline=false") : "";
		std::string desc = std::string("[echo") + rawCStr + newlineCStr + "]\t" + [text UTF8String] + "\n";
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
		std::string textStr([text UTF8String]);
		if(addNewline)
			PrintToStdOut(context, textStr + "\n", actionContext->index);
		else
			PrintToStdOut(context, std::move(textStr), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	return true;
}
