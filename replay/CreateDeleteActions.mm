#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#include "ABase64.h"
#include "PosixFileOps.h"
#include <cerrno>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

bool
CreateFile(const std::string &itemPath, const std::string &content, ReplayContext *context, ActionContext *actionContext)
{
	if(!context->mcpServer && context->stopOnError && (context->lastError.hasError()))
	{
		return false;
	}

	auto tryWrite = [&](const std::string &p) -> bool {
		std::ofstream f(p, std::ios::binary);
		if(!f.is_open())
		{
			return false;
		}
		if(!content.empty())
		{
			f.write(content.c_str(), (std::streamsize)content.size());
		}
		return f.good();
	};

	if(context->mcpServer)
	{
		bool isSuccessful = tryWrite(itemPath);
		if(!isSuccessful && context->force)
		{
			if(!posix_remove_recursive(itemPath))
			{
				posix_mkdir_p(posix_parent_dir(itemPath));
			}
			isSuccessful = tryWrite(itemPath);
		}
		if(!isSuccessful)
		{
			int err = errno;
			std::string errStr = std::string("failed to create file \"") + itemPath + "\": " + strerror(err);
			PrintMCPError(context, actionContext, -32603, std::move(errStr));
			return false;
		}
		PrintMCPTextResult(context, actionContext, std::string("Successfully wrote ") + itemPath);
		return true;
	}

	if(context->verbose || context->dryRun)
	{
		// settings access stays ObjC until Phase 5
		id useRawText = actionContext->settings[@"raw"];
		const char *settingsCStr = ([useRawText isKindOfClass:[NSNumber class]]) ? ([useRawText boolValue] ? " raw=true" : " raw=false") : "";
		std::string desc = std::string("[create file") + settingsCStr + "]\t" + itemPath + "\t" + content + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		isSuccessful = tryWrite(itemPath);

		if(!isSuccessful && context->force)
		{
			if(!posix_remove_recursive(itemPath))
			{
				posix_mkdir_p(posix_parent_dir(itemPath));
			}
			isSuccessful = tryWrite(itemPath);
		}

		if(!isSuccessful)
		{
			int err = errno;
			std::string errStr = std::string("error: failed to create file \"") + itemPath + "\". Error: " + strerror(err) + "\n";
			context->lastError.set(errStr, err);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
CreateFileFromBlob(const std::string &itemPath, const std::string &base64Content, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
	{
		return false;
	}

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[create file blob=true]\t") + itemPath + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		unsigned long encodedLen = base64Content.size();
		unsigned long maxDecoded = CalculateDecodedBufferMaxSize(encodedLen);
		std::vector<unsigned char> decoded(maxDecoded > 0 ? maxDecoded : 1);
		unsigned long decodedLen = encodedLen > 0
			? DecodeBase64((const unsigned char *)base64Content.c_str(), encodedLen, decoded.data(), maxDecoded)
			: 0;

		auto tryWrite = [&](const std::string &p) -> bool {
			std::ofstream f(p, std::ios::binary);
			if(!f.is_open())
			{
				return false;
			}
			if(decodedLen > 0)
			{
				f.write((const char *)decoded.data(), decodedLen);
			}
			return f.good();
		};

		isSuccessful = tryWrite(itemPath);
		if(!isSuccessful && context->force)
		{
			posix_remove_recursive(itemPath);
			posix_mkdir_p(posix_parent_dir(itemPath));
			isSuccessful = tryWrite(itemPath);
		}

		if(!isSuccessful)
		{
			int err = errno;
			std::string errStr = std::string("error: failed to create file \"") + itemPath + "\". Error: " + strerror(err) + "\n";
			context->lastError.set(errStr, err);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
CreateDirectory(const std::string &itemPath, ReplayContext *context, ActionContext *actionContext)
{
	if(!context->mcpServer && context->stopOnError && (context->lastError.hasError()))
	{
		return false;
	}

	if(context->mcpServer)
	{
		bool isSuccessful = posix_mkdir_p(itemPath);
		if(!isSuccessful)
		{
			int err = errno;
			std::string errStr = std::string("failed to create directory \"") + itemPath + "\": " + strerror(err);
			PrintMCPError(context, actionContext, -32603, std::move(errStr));
			return false;
		}
		PrintMCPTextResult(context, actionContext, std::string("Created directory ") + itemPath);
		return true;
	}

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[create directory]\t") + itemPath + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		isSuccessful = posix_mkdir_p(itemPath);
		if(!isSuccessful)
		{
			int err = errno;
			std::string errStr = std::string("error: failed to create directory \"") + itemPath + "\". Error: " + strerror(err) + "\n";
			context->lastError.set(errStr, err);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
DeleteItem(const std::string &itemPath, ReplayContext *context, ActionContext *actionContext)
{
	if(!context->mcpServer && context->stopOnError && (context->lastError.hasError()))
	{
		return false;
	}

	if(context->mcpServer)
	{
		bool isSuccessful = posix_remove_recursive(itemPath);
		if(!isSuccessful)
		{
			if(!posix_path_exists(itemPath))
			{
				PrintMCPTextResult(context, actionContext, std::string("Deleted ") + itemPath);
				return true;
			}
			int err = errno;
			std::string errStr = std::string("failed to delete \"") + itemPath + "\": " + strerror(err);
			PrintMCPError(context, actionContext, -32603, std::move(errStr));
			return false;
		}
		PrintMCPTextResult(context, actionContext, std::string("Deleted ") + itemPath);
		return true;
	}

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[delete]\t") + itemPath + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		isSuccessful = posix_remove_recursive(itemPath);
		if(!isSuccessful)
		{
			if(!posix_path_exists(itemPath))
			{
				return true;
			}
			int err = errno;
			std::string errStr = std::string("error: failed to delete \"") + itemPath + "\". Error: " + strerror(err) + "\n";
			context->lastError.set(errStr, err);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}
