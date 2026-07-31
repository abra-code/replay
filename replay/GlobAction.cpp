#include "ReplayAction.h"
#include "ReplayActionPrivate.h"
#include "FileSystemHelpers.h"
#include "yyjson.hpp"
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

		// Hitting the cap exactly is the only signal the glob engine gives us, so a
		// complete result set of exactly maxR entries reports truncated=true. Erring
		// toward "there may be more" is the safe direction: the caller re-runs with a
		// higher max and finds the same list, whereas a false negative silently hides
		// files. Before this, truncation was not reported at all.
		bool truncated = (matches.size() >= maxR);

		Json::MutableDoc doc;
		auto matchArray = doc.new_arr();
		for(const auto &m : matches)
			doc.arr_append(matchArray, doc.new_str(m));
		auto structured = doc.new_obj();
		doc.obj_add(structured, "matches",   matchArray);
		doc.obj_add(structured, "count",     doc.new_sint((int64_t)matches.size()));
		doc.obj_add(structured, "truncated", doc.new_bool(truncated));
		doc.set_root(structured);

		std::string summary;
		if(matches.empty())
			summary = "(no matches)";
		else
		{
			summary = "[" + std::to_string(matches.size()) + " match" +
			          (matches.size() == 1 ? "" : "es") + "]";
			if(truncated)
				summary += " [truncated at " + std::to_string(maxR) + "]";
		}
		PrintMCPResourceLinkResult(context, actionContext, std::move(summary), matches,
		                           doc.to_string());
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
