#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#include "FileSystemHelpers.h"
#include <cerrno>

bool
ListDirectory(const char *dirPath, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[list]\t%s\n", dirPath];
		PrintToStdOut(context, stdoutStr, actionContext->index);
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
		NSString *errStr = [NSString stringWithFormat:@"error: failed to list \"%s\": %s\n", dirPath, strerror(err)];
		PrintToStdErr(context, errStr);
		NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: errStr };
		context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:userInfo];
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	NSMutableString *output = [NSMutableString stringWithFormat:@"[list:%s]\n", dirPath];
	for(const auto &entry : entries)
		[output appendFormat:@"[%s] %s\n", entry.isDirectory ? "DIR" : "FILE", entry.name.c_str()];
	PrintToStdOut(context, output, actionContext->index);
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
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[tree]\t%s\n", dirPath];
		PrintToStdOut(context, stdoutStr, actionContext->index);
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
		NSString *errStr = [NSString stringWithFormat:@"error: failed to read directory \"%s\": %s\n", dirPath, strerror(err)];
		PrintToStdErr(context, errStr);
		NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: errStr };
		context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:userInfo];
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	NSError *jsonError = nil;
	NSData *jsonData = [NSJSONSerialization dataWithJSONObject:TreeNodeToObject(root)
	                                                   options:0
	                                                     error:&jsonError];
	NSString *jsonStr = jsonData
		? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]
		: @"{}";

	NSString *output = [NSString stringWithFormat:@"[tree:%s]\n%@\n", dirPath, jsonStr];
	PrintToStdOut(context, output, actionContext->index);
	return true;
}
