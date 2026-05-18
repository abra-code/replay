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
		for(const auto &e : entries)
		{
			text += e.isDirectory ? "[DIR]  " : "[FILE] ";
			text += e.name;
			text += "\n";
		}
		PrintMCPTextResult(context, actionContext, std::move(text));
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
			jsonStr = "{}";
		PrintMCPTextResult(context, actionContext, std::move(jsonStr));
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
