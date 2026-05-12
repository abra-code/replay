#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#include "ABase64.h"
#include <cerrno>
#include <fstream>
#include <string>
#include <vector>

bool
CreateFile(NSURL *itemURL, NSString *content, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
		return false;

	if(context->verbose || context->dryRun)
	{
		id useRawText = actionContext->settings[@"raw"];
		const char *settingsCStr = ([useRawText isKindOfClass:[NSNumber class]]) ? ([useRawText boolValue] ? " raw=true" : " raw=false") : "";
		std::string desc = std::string("[create file") + settingsCStr + "]\t" + [[itemURL path] UTF8String] + "\t" + [content UTF8String] + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
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
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];
			std::string errStr = std::string("error: failed to create file \"") + [[itemURL path] UTF8String] + "\". Error: " + ([errorDesc UTF8String] ?: "unknown") + "\n";
			context->lastError.set(errStr, (int)[operationError code]);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
CreateFileFromBlob(NSURL *itemURL, NSString *base64Content, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
		return false;

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[create file blob=true]\t") + [[itemURL path] UTF8String] + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
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
			std::string errStr = std::string("error: failed to create file \"") + [[itemURL path] UTF8String] + "\". Error: " + strerror(err) + "\n";
			context->lastError.set(errStr, err);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
CreateDirectory(NSURL *itemURL, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
		return false;

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[create directory]\t") + [[itemURL path] UTF8String] + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
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
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];
			std::string errStr = std::string("error: failed to create directory \"") + [[itemURL path] UTF8String] + "\". Error: " + ([errorDesc UTF8String] ?: "unknown") + "\n";
			context->lastError.set(errStr, (int)[operationError code]);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
DeleteItem(NSURL *itemURL, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
		return false;

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[delete]\t") + [[itemURL path] UTF8String] + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
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

			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];
			std::string errStr = std::string("error: failed to delete \"") + [[itemURL path] UTF8String] + "\". Error: " + ([errorDesc UTF8String] ?: "unknown") + "\n";
			context->lastError.set(errStr, (int)[operationError code]);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}
