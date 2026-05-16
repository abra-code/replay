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
CreateFile(NSURL *itemURL, NSString *content, ReplayContext *context, ActionContext *actionContext)
{
	if(!context->mcpServer && context->stopOnError && (context->lastError.hasError()))
	{
		return false;
	}

	const char *path = [[itemURL path] UTF8String];
	const char *utf8 = [content UTF8String];
	size_t len = (utf8 != nullptr) ? strlen(utf8) : 0;

	auto tryWrite = [&](const char *p) -> bool {
		std::ofstream f(p, std::ios::binary);
		if(!f.is_open())
		{
			return false;
		}
		if(len > 0)
		{
			f.write(utf8, (std::streamsize)len);
		}
		return f.good();
	};

	if(context->mcpServer)
	{
		bool isSuccessful = tryWrite(path);
		if(!isSuccessful && context->force)
		{
			if(!posix_remove_recursive(path))
			{
				std::string parentPath = posix_parent_dir(path);
				posix_mkdir_p(parentPath.c_str());
			}
			isSuccessful = tryWrite(path);
		}
		if(!isSuccessful)
		{
			int err = errno;
			std::string errStr = std::string("failed to create file \"") + path + "\": " + strerror(err);
			PrintMCPError(context, actionContext, -32603, std::move(errStr));
			return false;
		}
		PrintMCPTextResult(context, actionContext, std::string("Successfully wrote ") + path);
		return true;
	}

	if(context->verbose || context->dryRun)
	{
		// settings access stays ObjC until Phase 5
		id useRawText = actionContext->settings[@"raw"];
		const char *settingsCStr = ([useRawText isKindOfClass:[NSNumber class]]) ? ([useRawText boolValue] ? " raw=true" : " raw=false") : "";
		std::string desc = std::string("[create file") + settingsCStr + "]\t" + path + "\t" + (utf8 != nullptr ? utf8 : "") + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		isSuccessful = tryWrite(path);

		if(!isSuccessful && context->force)
		{
			if(!posix_remove_recursive(path))
			{
				std::string parentPath = posix_parent_dir(path);
				posix_mkdir_p(parentPath.c_str());
			}
			isSuccessful = tryWrite(path);
		}

		if(!isSuccessful)
		{
			int err = errno;
			std::string errStr = std::string("error: failed to create file \"") + path + "\". Error: " + strerror(err) + "\n";
			context->lastError.set(errStr, err);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
CreateFileFromBlob(NSURL *itemURL, NSString *base64Content, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
	{
		return false;
	}

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[create file blob=true]\t") + [[itemURL path] UTF8String] + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		const char *encoded = [base64Content UTF8String];
		unsigned long encodedLen = (encoded != nullptr) ? strlen(encoded) : 0;
		unsigned long maxDecoded = CalculateDecodedBufferMaxSize(encodedLen);
		std::vector<unsigned char> decoded(maxDecoded > 0 ? maxDecoded : 1);
		unsigned long decodedLen = encodedLen > 0
			? DecodeBase64((const unsigned char *)encoded, encodedLen, decoded.data(), maxDecoded)
			: 0;

		const char *path = [[itemURL path] UTF8String];
		auto tryWrite = [&](const char *p) -> bool {
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

		isSuccessful = tryWrite(path);
		if(!isSuccessful && context->force)
		{
			posix_remove_recursive(path);
			std::string parentPath = posix_parent_dir(path);
			posix_mkdir_p(parentPath.c_str());
			isSuccessful = tryWrite(path);
		}

		if(!isSuccessful)
		{
			int err = errno;
			std::string errStr = std::string("error: failed to create file \"") + path + "\". Error: " + strerror(err) + "\n";
			context->lastError.set(errStr, err);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
CreateDirectory(NSURL *itemURL, ReplayContext *context, ActionContext *actionContext)
{
	if(!context->mcpServer && context->stopOnError && (context->lastError.hasError()))
	{
		return false;
	}

	const char *path = [[itemURL path] UTF8String];

	if(context->mcpServer)
	{
		bool isSuccessful = posix_mkdir_p(path);
		if(!isSuccessful)
		{
			int err = errno;
			std::string errStr = std::string("failed to create directory \"") + path + "\": " + strerror(err);
			PrintMCPError(context, actionContext, -32603, std::move(errStr));
			return false;
		}
		PrintMCPTextResult(context, actionContext, std::string("Created directory ") + path);
		return true;
	}

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[create directory]\t") + path + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		isSuccessful = posix_mkdir_p(path);
		if(!isSuccessful)
		{
			int err = errno;
			std::string errStr = std::string("error: failed to create directory \"") + path + "\". Error: " + strerror(err) + "\n";
			context->lastError.set(errStr, err);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
DeleteItem(NSURL *itemURL, ReplayContext *context, ActionContext *actionContext)
{
	if(!context->mcpServer && context->stopOnError && (context->lastError.hasError()))
	{
		return false;
	}

	const char *path = [[itemURL path] UTF8String];

	if(context->mcpServer)
	{
		bool isSuccessful = posix_remove_recursive(path);
		if(!isSuccessful)
		{
			if(!posix_path_exists(path))
			{
				PrintMCPTextResult(context, actionContext, std::string("Deleted ") + path);
				return true;
			}
			int err = errno;
			std::string errStr = std::string("failed to delete \"") + path + "\": " + strerror(err);
			PrintMCPError(context, actionContext, -32603, std::move(errStr));
			return false;
		}
		PrintMCPTextResult(context, actionContext, std::string("Deleted ") + path);
		return true;
	}

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[delete]\t") + path + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		isSuccessful = posix_remove_recursive(path);
		if(!isSuccessful)
		{
			if(!posix_path_exists(path))
			{
				return true;
			}
			int err = errno;
			std::string errStr = std::string("error: failed to delete \"") + path + "\". Error: " + strerror(err) + "\n";
			context->lastError.set(errStr, err);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}
