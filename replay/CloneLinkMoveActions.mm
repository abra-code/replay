#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#include <string>

bool
CloneItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
		return false;

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[clone]\t") + [[fromURL path] UTF8String] + "\t" + [[toURL path] UTF8String] + "\n";
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
		isSuccessful = (bool)[fileManager copyItemAtURL:(NSURL *)fromURL toURL:(NSURL *)toURL error:&operationError];

		if(!isSuccessful && context->force)
		{
			bool removalOK = [fileManager removeItemAtURL:toURL error:nil];
			if(!removalOK)
			{
				NSURL *parentDirURL = [toURL URLByDeletingLastPathComponent];
				[fileManager createDirectoryAtURL:parentDirURL withIntermediateDirectories:YES attributes:nil error:nil];
			}
			isSuccessful = (bool)[fileManager copyItemAtURL:(NSURL *)fromURL toURL:(NSURL *)toURL error:&operationError];
		}

		if(!isSuccessful)
		{
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];
			std::string errStr = std::string("error: failed to clone from \"") + [[fromURL path] UTF8String] + "\" to \"" + [[toURL path] UTF8String] + "\". Error: " + ([errorDesc UTF8String] ?: "unknown") + "\n";
			context->lastError.set(errStr, (int)[operationError code]);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
MoveItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
		return false;

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[move]\t") + [[fromURL path] UTF8String] + "\t" + [[toURL path] UTF8String] + "\n";
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
		isSuccessful = (bool)[fileManager moveItemAtURL:fromURL toURL:toURL error:&operationError];

		if(!isSuccessful && context->force)
		{
			bool removalOK = [fileManager removeItemAtURL:toURL error:nil];
			if(!removalOK)
			{
				NSURL *parentDirURL = [toURL URLByDeletingLastPathComponent];
				[fileManager createDirectoryAtURL:parentDirURL withIntermediateDirectories:YES attributes:nil error:nil];
			}
			isSuccessful = (bool)[fileManager moveItemAtURL:fromURL toURL:toURL error:&operationError];
		}

		if(!isSuccessful)
		{
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];
			std::string errStr = std::string("error: failed to move from \"") + [[fromURL path] UTF8String] + "\" to \"" + [[toURL path] UTF8String] + "\". Error: " + ([errorDesc UTF8String] ?: "unknown") + "\n";
			context->lastError.set(errStr, (int)[operationError code]);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
HardlinkItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
		return false;

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[hardlink]\t") + [[fromURL path] UTF8String] + "\t" + [[toURL path] UTF8String] + "\n";
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
		isSuccessful = (bool)[fileManager linkItemAtURL:fromURL toURL:toURL error:&operationError];

		if(!isSuccessful && context->force)
		{
			bool removalOK = [fileManager removeItemAtURL:toURL error:nil];
			if(!removalOK)
			{
				NSURL *parentDirURL = [toURL URLByDeletingLastPathComponent];
				[fileManager createDirectoryAtURL:parentDirURL withIntermediateDirectories:YES attributes:nil error:nil];
			}
			isSuccessful = (bool)[fileManager linkItemAtURL:fromURL toURL:toURL error:&operationError];
		}

		if(!isSuccessful)
		{
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];
			std::string errStr = std::string("error: failed to create a hardlink from \"") + [[fromURL path] UTF8String] + "\" to \"" + [[toURL path] UTF8String] + "\". Error: " + ([errorDesc UTF8String] ?: "unknown") + "\n";
			context->lastError.set(errStr, (int)[operationError code]);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
SymlinkItem(NSURL *fromURL, NSURL *linkURL, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
		return false;

	NSNumber *validateSource = actionContext->settings[@"validate"];
	bool validateSymlinkSource = true;
	if([validateSource isKindOfClass:[NSNumber class]])
		validateSymlinkSource = [validateSource boolValue];

	if(context->verbose || context->dryRun)
	{
		const char *settingsCStr = (validateSource == nil) ? "" : (validateSymlinkSource ? " validate=true" : " validate=false");
		std::string desc = std::string("[symlink") + settingsCStr + "]\t" + [[fromURL path] UTF8String] + "\t" + [[linkURL path] UTF8String] + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool force = context->force;
	bool isSuccessful = context->dryRun;

	if(!context->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;

		if(validateSymlinkSource && ![fileManager fileExistsAtPath:[fromURL path]])
		{
			isSuccessful = false;
			force = false;
		}
		else
		{
			isSuccessful = (bool)[fileManager createSymbolicLinkAtURL:linkURL withDestinationURL:(NSURL *)fromURL error:&operationError];
		}

		if(!isSuccessful && force)
		{
			bool removalOK = [fileManager removeItemAtURL:linkURL error:nil];
			if(!removalOK)
			{
				NSURL *parentDirURL = [linkURL URLByDeletingLastPathComponent];
				[fileManager createDirectoryAtURL:parentDirURL withIntermediateDirectories:YES attributes:nil error:nil];
			}
			isSuccessful = (bool)[fileManager createSymbolicLinkAtURL:linkURL withDestinationURL:(NSURL *)fromURL error:&operationError];
		}

		if(!isSuccessful)
		{
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];
			std::string errStr = std::string("error: failed to create a symlink at \"") + [[linkURL path] UTF8String] + "\" referring to \"" + [[fromURL path] UTF8String] + "\". Error: " + ([errorDesc UTF8String] ?: "unknown") + "\n";
			context->lastError.set(errStr, operationError ? (int)[operationError code] : 1);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}
