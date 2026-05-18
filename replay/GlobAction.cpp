#include "ReplayAction.h"
#include "ReplayActionPrivate.h"
#include "FileSystemHelpers.h"
#include <string>
#include <vector>

bool
GlobFiles(const std::string &rootDir, const std::vector<std::string> &globPatterns,
          const std::vector<std::string> &excludePatterns, intptr_t maxResults,
          ReplayContext *context, ActionContext *actionContext)
{
	if(!context->mcpServer && context->stopOnError && context->lastError.hasError())
		return false;

	if(context->mcpServer)
	{
		size_t maxR = (maxResults > 0) ? (size_t)maxResults : 1000;
		auto matches = glob_files_in_dir(rootDir, globPatterns, excludePatterns, maxR);
		std::string text;
		for(const auto &m : matches) { text += m; text += "\n"; }
		if(text.empty())
			text = "(no matches)";
		PrintMCPTextResult(context, actionContext, std::move(text));
		return true;
	}

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[glob]\t") + rootDir;
		for(const auto &p : globPatterns)
			{ desc += "\t"; desc += p; }
		for(const auto &p : excludePatterns)
			{ desc += "\t!"; desc += p; }
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

	size_t maxR = (maxResults > 0) ? (size_t)maxResults : 1000;
	auto matches = glob_files_in_dir(rootDir, globPatterns, excludePatterns, maxR);

	std::string output = "[glob]\n";
	for(const auto &m : matches)
		{ output += m; output += "\n"; }
	PrintToStdOut(context, std::move(output), actionContext->index);
	return true;
}
