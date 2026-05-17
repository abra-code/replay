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
	if(!context->mcpServer && context->stopOnError && context->lastError.hasError())
		return false;

	if(context->mcpServer)
	{
		std::string cRoot([rootDir UTF8String]);
		std::vector<std::string> cGlobs;
		for(NSString *p in globPatterns)
			if(p != nil)
				cGlobs.push_back(std::string([p UTF8String]));
		std::vector<std::string> cExcludes;
		for(NSString *p in excludePatterns)
			if(p != nil)
				cExcludes.push_back(std::string([p UTF8String]));
		size_t maxR = (maxResults > 0) ? (size_t)maxResults : 1000;
		auto matches = glob_files_in_dir(cRoot, cGlobs, cExcludes, maxR);
		std::string text;
		for(const auto &m : matches) { text += m; text += "\n"; }
		if(text.empty())
			text = "(no matches)";
		PrintMCPTextResult(context, actionContext, std::move(text));
		return true;
	}

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[glob]\t") + [rootDir UTF8String];
		for(NSString *p in globPatterns)
			{ desc += "\t"; desc += [p UTF8String]; }
		for(NSString *p in excludePatterns)
			{ desc += "\t!"; desc += [p UTF8String]; }
		desc += "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
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
		if(p != nil)
			cGlobs.push_back(std::string([p UTF8String]));

	std::vector<std::string> cExcludes;
	for(NSString *p in excludePatterns)
		if(p != nil)
			cExcludes.push_back(std::string([p UTF8String]));

	size_t maxR = (maxResults > 0) ? (size_t)maxResults : 1000;
	auto matches = glob_files_in_dir(cRoot, cGlobs, cExcludes, maxR);

	std::string output = "[glob]\n";
	for(const auto &m : matches)
		{ output += m; output += "\n"; }
	PrintToStdOut(context, std::move(output), actionContext->index);
	return true;
}
