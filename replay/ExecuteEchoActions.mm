#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"

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
		NSString *settingsStr = @"";
		if(useStdOutNum != nil)
			settingsStr = useStdOut ? @" stdout=true" : @" stdout=false";
		NSString *allArgsStr = [arguments componentsJoinedByString:@"\t"];
		NSString *stdoutStr = [NSString stringWithFormat:@"[execute%@]	%@	%@\n", settingsStr, toolPath, allArgsStr];
		PrintToStdOut(context, stdoutStr, actionContext->index);
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
					NSString *stdErrStr = [[NSString alloc] initWithData:stdErrData encoding:NSUTF8StringEncoding];
					PrintToStdErr(context, stdErrStr);
				}

				NSString *toolErrorDescription = [NSString stringWithFormat:@"%@ returned error %d", toolPath, toolStatus];
				NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: toolErrorDescription };
				NSError *taskError = [NSError errorWithDomain:NSPOSIXErrorDomain code:toolStatus userInfo:userInfo];
				context->lastError.error = taskError;
				NSString *errStr = [NSString stringWithFormat:@"error: failed to execute \"%@\". Error: %d\n", toolPath, toolStatus];
				PrintToStdErr(context, errStr);
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
					NSString *stdOutStr = [[NSString alloc] initWithData:stdOutData encoding:NSUTF8StringEncoding];
					PrintToStdOut(context, stdOutStr, actionContext->index);
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
			NSString *errStr = [NSString stringWithFormat:@"error: failed to execute \"%@\". Error: %@\n", toolPath, errorDesc];
			PrintToStdErr(context, errStr);
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
		NSString *rawSetting = @"";
		if([useRawText isKindOfClass:[NSNumber class]])
			rawSetting = [useRawText boolValue] ? @" raw=true" : @" raw=false";

		NSString *newlineSetting = @"";
		if(newlineVal != nil)
			newlineSetting = addNewline ? @" newline=true" : @" newline=false";

		NSString *stdoutStr = [NSString stringWithFormat:@"[echo%@%@]	%@\n", rawSetting, newlineSetting, text];
		PrintToStdOut(context, stdoutStr, actionContext->index);
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
		{
			NSArray<NSString *> *array = @[text, @"\n"];
			PrintStringsToStdOut(context, array, actionContext->index);
		}
		else
		{
			PrintToStdOut(context, text, actionContext->index);
		}
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	return true;
}
