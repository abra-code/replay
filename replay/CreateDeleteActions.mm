#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#include "ABase64.h"
#include <cerrno>
#include <fstream>
#include <vector>
#include <string>

bool
CreateFile(NSURL *itemURL, NSString *content, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		id useRawText = actionContext->settings[@"raw"];
		NSString *settingsStr = @"";
		if([useRawText isKindOfClass:[NSNumber class]])
			settingsStr = [useRawText boolValue] ? @" raw=true" : @" raw=false";
		NSString *stdoutStr = [NSString stringWithFormat:@"[create file%@]	%@	%@\n", settingsStr, [itemURL path], content];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		NSError *operationError = nil;
		isSuccessful = [content writeToURL:itemURL atomically:NO encoding:NSUTF8StringEncoding error:&operationError];

		if(!isSuccessful && context->force)
		{
			NSFileManager *fileManager = [NSFileManager defaultManager];
			bool removalOK = [fileManager removeItemAtURL:itemURL error:nil];
			if(!removalOK)
			{
				NSURL *parentDirURL = [itemURL URLByDeletingLastPathComponent];
				[fileManager createDirectoryAtURL:parentDirURL withIntermediateDirectories:YES attributes:nil error:nil];
			}
			isSuccessful = [content writeToURL:itemURL atomically:NO encoding:NSUTF8StringEncoding error:&operationError];
		}

		if(!isSuccessful)
		{
			context->lastError.error = operationError;
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];
			NSString *errStr = [NSString stringWithFormat:@"error: failed to create file \"%@\". Error: %@\n",
			                    [itemURL path], errorDesc];
			PrintToStdErr(context, errStr);
		}
	}
	return isSuccessful;
}

bool
CreateFileFromBlob(NSURL *itemURL, NSString *base64Content, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[create file blob=true]\t%@\n", [itemURL path]];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		const char *encoded = [base64Content UTF8String];
		unsigned long encodedLen = encoded ? strlen(encoded) : 0;
		unsigned long maxDecoded = CalculateDecodedBufferMaxSize(encodedLen);
		std::vector<unsigned char> decoded(maxDecoded > 0 ? maxDecoded : 1);
		unsigned long decodedLen = encodedLen > 0
			? DecodeBase64((const unsigned char *)encoded, encodedLen, decoded.data(), maxDecoded)
			: 0;

		const char *path = [[itemURL path] UTF8String];
		auto tryWrite = [&](const char *p) -> bool {
			std::ofstream f(p, std::ios::binary);
			if(!f.is_open()) return false;
			if(decodedLen > 0) f.write((const char *)decoded.data(), decodedLen);
			return f.good();
		};

		isSuccessful = tryWrite(path);
		if(!isSuccessful && context->force)
		{
			NSFileManager *fm = [NSFileManager defaultManager];
			[fm removeItemAtURL:itemURL error:nil];
			NSURL *parentDirURL = [itemURL URLByDeletingLastPathComponent];
			[fm createDirectoryAtURL:parentDirURL withIntermediateDirectories:YES attributes:nil error:nil];
			isSuccessful = tryWrite(path);
		}

		if(!isSuccessful)
		{
			int err = errno;
			NSString *errStr = [NSString stringWithFormat:@"error: failed to create file \"%@\". Error: %s\n",
			                    [itemURL path], strerror(err)];
			PrintToStdErr(context, errStr);
			NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: errStr };
			context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:userInfo];
		}
	}
	return isSuccessful;
}

bool
CreateDirectory(NSURL *itemURL, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[create directory]	%@\n", [itemURL path]];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;
		isSuccessful = [fileManager createDirectoryAtURL:itemURL withIntermediateDirectories:YES attributes:nil error:&operationError];

		if(!isSuccessful)
		{
			context->lastError.error = operationError;
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];
			NSString *errStr = [NSString stringWithFormat:@"error: failed to create directory \"%@\". Error: %@\n",
			                    [itemURL path], errorDesc];
			PrintToStdErr(context, errStr);
		}
	}
	return isSuccessful;
}

bool
DeleteItem(NSURL *itemURL, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[delete]	%@\n", [itemURL path]];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;
		isSuccessful = (bool)[fileManager removeItemAtURL:itemURL error:&operationError];
		if(!isSuccessful)
		{
			if(![fileManager fileExistsAtPath:[itemURL path]])
				return true;

			context->lastError.error = operationError;
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];
			NSString *errStr = [NSString stringWithFormat:@"error: failed to delete \"%@\". Error: %@\n",
			                    [itemURL path], errorDesc];
			PrintToStdErr(context, errStr);
		}
	}
	return isSuccessful;
}
