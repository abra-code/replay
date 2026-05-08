#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#include "FileSystemHelpers.h"
#include <string>
#include <vector>

bool
GlobFiles(NSString *rootDir, NSArray<NSString*> *globPatterns, NSArray<NSString*> *excludePatterns,
          NSInteger maxResults, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && context->lastError.error != nil)
		return false;

	if(context->verbose || context->dryRun)
	{
		NSMutableString *desc = [NSMutableString stringWithFormat:@"[glob]\t%@", rootDir];
		for(NSString *p in globPatterns)
			[desc appendFormat:@"\t%@", p];
		for(NSString *p in excludePatterns)
			[desc appendFormat:@"\t!%@", p];
		[desc appendString:@"\n"];
		PrintToStdOut(context, desc, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	actionContext->index++;

	if(context->dryRun)
	{
		ActionWithNoOutput(context, actionContext->index);
		return true;
	}

	std::string cRoot([rootDir UTF8String]);

	std::vector<std::string> cGlobs;
	for(NSString *p in globPatterns)
		if(p != nil) cGlobs.push_back(std::string([p UTF8String]));

	std::vector<std::string> cExcludes;
	for(NSString *p in excludePatterns)
		if(p != nil) cExcludes.push_back(std::string([p UTF8String]));

	size_t maxR = (maxResults > 0) ? (size_t)maxResults : 1000;
	auto matches = glob_files_in_dir(cRoot, cGlobs, cExcludes, maxR);

	NSMutableString *output = [NSMutableString stringWithString:@"[glob]\n"];
	for(const auto &m : matches)
		[output appendFormat:@"%s\n", m.c_str()];
	PrintToStdOut(context, output, actionContext->index);
	return true;
}
