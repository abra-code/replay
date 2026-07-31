#include "ReplayAction.h"
#include "ReplayActionPrivate.h"
#include "FileSystemHelpers.h"
#include "yyjson.hpp"
#include <cerrno>

bool
ListDirectory(const std::string &dirPath, ReplayContext *context, ActionContext *actionContext)
{
	if(!context->mcpServer && context->stopOnError && (context->lastError.hasError()))
		return false;

	if(context->mcpServer)
	{
		std::vector<DirEntry> entries;
		if(!list_directory(dirPath.c_str(), entries))
		{
			int err = errno;
			std::string errStr = std::string("failed to list \"") + dirPath + "\": " + strerror(err);
			PrintMCPError(context, actionContext, -32603, std::move(errStr));
			return false;
		}
		std::string text;
		Json::MutableDoc doc;
		auto entryArray = doc.new_arr();
		for(const auto &e : entries)
		{
			text += e.isDirectory ? "[DIR]  " : "[FILE] ";
			text += e.name;
			text += "\n";

			// The [DIR]/[FILE] prefix as a field, so a caller does not have to match on
			// the padding - the markers are deliberately different widths for alignment.
			auto entry = doc.new_obj();
			doc.obj_add(entry, "name", doc.new_str(e.name));
			doc.obj_add(entry, "type", doc.new_str(e.isDirectory ? "directory" : "file"));
			doc.arr_append(entryArray, entry);
		}
		auto structured = doc.new_obj();
		doc.obj_add(structured, "entries", entryArray);
		doc.set_root(structured);

		PrintMCPStructuredResult(context, actionContext, std::move(text), doc.to_string());
		return true;
	}

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[list]\t") + dirPath + "\n";
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

	std::vector<DirEntry> entries;
	if(!list_directory(dirPath.c_str(), entries))
	{
		int err = errno;
		std::string errStr = std::string("error: failed to list \"") + dirPath + "\": " + strerror(err) + "\n";
		context->lastError.set(errStr, err);
		PrintToStdErr(context, std::move(errStr));
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	std::string output = std::string("[list:") + dirPath + "]\n";
	for(const auto &entry : entries)
	{
		output += entry.isDirectory ? "[DIR] " : "[FILE] ";
		output += entry.name;
		output += "\n";
	}
	PrintToStdOut(context, std::move(output), actionContext->index);
	return true;
}

static Json::MutableVal TreeNodeToVal(Json::MutableDoc &doc, const TreeNode &node)
{
	Json::MutableVal obj = doc.new_obj();
	doc.obj_add(obj, "name", doc.new_str(node.name));
	doc.obj_add(obj, "type", doc.new_str(node.isDirectory ? "directory" : "file"));
	if(node.isDirectory)
	{
		Json::MutableVal children = doc.new_arr();
		for(const auto &child : node.children)
			doc.arr_append(children, TreeNodeToVal(doc, child));
		doc.obj_add(obj, "children", children);
	}
	return obj;
}

bool
DirectoryTree(const std::string &dirPath, intptr_t maxDepth, ReplayContext *context, ActionContext *actionContext)
{
	if(!context->mcpServer && context->stopOnError && (context->lastError.hasError()))
		return false;

	if(context->mcpServer)
	{
		TreeNode root;
		if(!build_directory_tree(dirPath.c_str(), root, (int)maxDepth))
		{
			int err = errno;
			std::string errStr = std::string("failed to read directory \"") + dirPath + "\": " + strerror(err);
			PrintMCPError(context, actionContext, -32603, std::move(errStr));
			return false;
		}
		Json::MutableDoc doc;
		doc.set_root(TreeNodeToVal(doc, root));
		std::string jsonStr = doc.to_string();
		if(jsonStr.empty())
		{
			// Was "{}", which is not a tree - it satisfies neither the caller nor the
			// declared outputSchema, whose required keys are name and type. Serializing
			// a tree we just built should not fail, so if it does, say so rather than
			// hand back a well-formed lie.
			PrintMCPError(context, actionContext, -32603,
			              std::string("failed to serialize directory tree for \"") + dirPath + "\"");
			return false;
		}
		// This tool already answered in JSON, just wrapped in a text block. The same
		// document now also goes in structuredContent, so a client no longer has to
		// know that content[0].text happens to be parseable. The text block keeps the
		// identical bytes, which is exactly the mirror the spec asks for here.
		PrintMCPStructuredResult(context, actionContext, jsonStr, jsonStr);
		return true;
	}

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[tree]\t") + dirPath + "\n";
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

	TreeNode root;
	if(!build_directory_tree(dirPath.c_str(), root, (int)maxDepth))
	{
		int err = errno;
		std::string errStr = std::string("error: failed to read directory \"") + dirPath + "\": " + strerror(err) + "\n";
		context->lastError.set(errStr, err);
		PrintToStdErr(context, std::move(errStr));
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	Json::MutableDoc doc;
	doc.set_root(TreeNodeToVal(doc, root));
	std::string jsonStr = doc.to_string();
	if(jsonStr.empty())
		jsonStr = "{}";

	std::string output;
	output.reserve(6 + dirPath.size() + 2 + jsonStr.size() + 1);
	output += "[tree:";
	output += dirPath;
	output += "]\n";
	output += jsonStr;
	output += "\n";
	PrintToStdOut(context, std::move(output), actionContext->index);
	return true;
}
