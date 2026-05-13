#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#include "FileSystemHelpers.h"
#include <cerrno>

bool
ListDirectory(const char *dirPath, ReplayContext *context, ActionContext *actionContext)
{
	if(!context->mcpServer && context->stopOnError && (context->lastError.hasError()))
		return false;

	if(context->mcpServer)
	{
		std::vector<DirEntry> entries;
		if(!list_directory(dirPath, entries))
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
	if(!list_directory(dirPath, entries))
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

static id TreeNodeToObject(const TreeNode &node)
{
	NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:3];
	dict[@"name"] = @(node.name.c_str());
	dict[@"type"] = node.isDirectory ? @"directory" : @"file";
	if(node.isDirectory)
	{
		NSMutableArray *children = [NSMutableArray arrayWithCapacity:node.children.size()];
		for(const auto &child : node.children)
			[children addObject:TreeNodeToObject(child)];
		dict[@"children"] = children;
	}
	return dict;
}

bool
DirectoryTree(const char *dirPath, NSInteger maxDepth, ReplayContext *context, ActionContext *actionContext)
{
	if(!context->mcpServer && context->stopOnError && (context->lastError.hasError()))
		return false;

	if(context->mcpServer)
	{
		TreeNode root;
		if(!build_directory_tree(dirPath, root, (int)maxDepth))
		{
			int err = errno;
			std::string errStr = std::string("failed to read directory \"") + dirPath + "\": " + strerror(err);
			PrintMCPError(context, actionContext, -32603, std::move(errStr));
			return false;
		}
		NSError *jsonError = nil;
		NSData *jsonData = [NSJSONSerialization dataWithJSONObject:TreeNodeToObject(root)
		                                                   options:0
		                                                     error:&jsonError];
		const char *jsonBytes = jsonData ? (const char *)[jsonData bytes] : "{}";
		size_t jsonLen = jsonData ? (size_t)[jsonData length] : 2;
		PrintMCPTextResult(context, actionContext, std::string(jsonBytes, jsonLen));
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
	if(!build_directory_tree(dirPath, root, (int)maxDepth))
	{
		int err = errno;
		std::string errStr = std::string("error: failed to read directory \"") + dirPath + "\": " + strerror(err) + "\n";
		context->lastError.set(errStr, err);
		PrintToStdErr(context, std::move(errStr));
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	NSError *jsonError = nil;
	NSData *jsonData = [NSJSONSerialization dataWithJSONObject:TreeNodeToObject(root)
	                                                   options:0
	                                                     error:&jsonError];
	const char *jsonBytes = jsonData ? (const char *)[jsonData bytes] : "{}";
	size_t jsonLen = jsonData ? (size_t)[jsonData length] : 2;

	std::string output;
	output.reserve(strlen("[tree:") + strlen(dirPath) + 2 + jsonLen + 1);
	output += "[tree:";
	output += dirPath;
	output += "]\n";
	output.append(jsonBytes, jsonLen);
	output += "\n";
	PrintToStdOut(context, std::move(output), actionContext->index);
	return true;
}
