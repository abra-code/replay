#import "StringAndPath.h"
#include "EnvVarExpand.h"

NSString *
StringByExpandingEnvironmentVariablesWithErrorCheck(NSString *origString, ReplayContext *context)
{
	auto result = expand_env_vars([origString UTF8String], context->environment);
	if(!result.has_value())
	{
		LogError("error: missing or unterminated environment variable in \"%s\"\n", [origString UTF8String]);
		context->lastError.set("error: malformed string or missing environment variable", 1);
		return nil;
	}
	return [NSString stringWithUTF8String:result->c_str()];
}


std::optional<std::string>
ExpandEnvVars(const char *str, ReplayContext *context)
{
	if(str == nullptr)
		return std::nullopt;
	auto result = expand_env_vars(str, context->environment);
	if(!result.has_value())
	{
		LogError("error: missing or unterminated environment variable in \"%s\"\n", str);
		context->lastError.set("error: malformed string or missing environment variable", 1);
	}
	return result;
}


NSArray<NSURL*> *
ItemPathsToURLs(NSArray<NSString*> *itemPaths, ReplayContext *context)
{
	NSUInteger fileCount = [itemPaths count];
	NSMutableArray *itemURLs = [NSMutableArray arrayWithCapacity:fileCount];

	for(NSString *itemPath in itemPaths)
	{
		NSString *expandedFileName = StringByExpandingEnvironmentVariablesWithErrorCheck(itemPath, context);
		if(expandedFileName != nil)
		{
			NSURL *itemURL = [NSURL fileURLWithPath:expandedFileName];
			[itemURLs addObject:itemURL];
		}
		else if(context->stopOnError)
		{
			return nil;
		}
	}

	return itemURLs;
}

// When an operation is specified as a list of source items and destination dir,
// create an explicit list of destination URLs corresponding to source file names.
// If more than one source file has the same name, items will be overwritten.
NSArray<NSURL*> *
GetDestinationsForMultipleItems(NSArray<NSURL*> *sourceItemURLs, NSURL *destinationDirectoryURL, ReplayContext *context)
{
	if(sourceItemURLs == nil || destinationDirectoryURL == nil)
	{
		return nil;
	}

	NSUInteger itemCount = [sourceItemURLs count];
	NSMutableArray *destinationURLs = [NSMutableArray arrayWithCapacity:itemCount];

	for(NSURL *srcItemURL in sourceItemURLs)
	{
		NSString *fileName = [srcItemURL lastPathComponent];
		NSURL *destURL = [destinationDirectoryURL URLByAppendingPathComponent:fileName];
		[destinationURLs addObject:destURL];
	}

	return destinationURLs;
}
