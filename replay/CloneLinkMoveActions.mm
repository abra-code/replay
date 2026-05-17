#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#include "PosixFileOps.h"
#include <cerrno>
#include <cstring>
#include <string>
#include <unistd.h>

bool
CloneItem(const std::string &fromPath, const std::string &toPath, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
	{
		return false;
	}

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[clone]\t") + fromPath + "\t" + toPath + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		int rc = posix_clone_item(fromPath, toPath);
		isSuccessful = (rc == 0);

		if(!isSuccessful && context->force)
		{
			if(!posix_remove_recursive(toPath))
			{
				std::string parentPath = posix_parent_dir(toPath);
				posix_mkdir_p(parentPath);
			}
			rc = posix_clone_item(fromPath, toPath);
			isSuccessful = (rc == 0);
		}

		if(!isSuccessful)
		{
			int err = errno;
			std::string errStr = std::string("error: failed to clone from \"") + fromPath + "\" to \"" + toPath + "\". Error: " + strerror(err) + "\n";
			context->lastError.set(errStr, err);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
MoveItem(const std::string &fromPath, const std::string &toPath, ReplayContext *context, ActionContext *actionContext)
{
	if(!context->mcpServer && context->stopOnError && (context->lastError.hasError()))
	{
		return false;
	}

	if(context->mcpServer)
	{
		bool isSuccessful = posix_move_item(fromPath, toPath);
		if(!isSuccessful && context->force)
		{
			posix_remove_recursive(toPath);
			std::string parentPath = posix_parent_dir(toPath);
			posix_mkdir_p(parentPath);
			isSuccessful = posix_move_item(fromPath, toPath);
		}
		if(!isSuccessful)
		{
			int err = errno;
			std::string errStr = std::string("failed to move from \"") + fromPath + "\" to \"" + toPath + "\": " + strerror(err);
			PrintMCPError(context, actionContext, -32603, std::move(errStr));
			return false;
		}
		PrintMCPTextResult(context, actionContext, std::string("Moved ") + fromPath + " -> " + toPath);
		return true;
	}

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[move]\t") + fromPath + "\t" + toPath + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		isSuccessful = posix_move_item(fromPath, toPath);

		if(!isSuccessful && context->force)
		{
			if(!posix_remove_recursive(toPath))
			{
				std::string parentPath = posix_parent_dir(toPath);
				posix_mkdir_p(parentPath);
			}
			isSuccessful = posix_move_item(fromPath, toPath);
		}

		if(!isSuccessful)
		{
			int err = errno;
			std::string errStr = std::string("error: failed to move from \"") + fromPath + "\" to \"" + toPath + "\". Error: " + strerror(err) + "\n";
			context->lastError.set(errStr, err);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
HardlinkItem(const std::string &fromPath, const std::string &toPath, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
	{
		return false;
	}

	if(context->verbose || context->dryRun)
	{
		std::string desc = std::string("[hardlink]\t") + fromPath + "\t" + toPath + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		isSuccessful = (link(fromPath.c_str(), toPath.c_str()) == 0);

		if(!isSuccessful && context->force)
		{
			if(!posix_remove_recursive(toPath))
			{
				std::string parentPath = posix_parent_dir(toPath);
				posix_mkdir_p(parentPath);
			}
			isSuccessful = (link(fromPath.c_str(), toPath.c_str()) == 0);
		}

		if(!isSuccessful)
		{
			int err = errno;
			std::string errStr = std::string("error: failed to create a hardlink from \"") + fromPath + "\" to \"" + toPath + "\". Error: " + strerror(err) + "\n";
			context->lastError.set(errStr, err);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}

bool
SymlinkItem(const std::string &fromPath, const std::string &linkPath, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.hasError()))
	{
		return false;
	}

	bool validateSymlinkSource = actionContext->settings.bool_value("validate", true);

	if(context->verbose || context->dryRun)
	{
		const char *settingsCStr = validateSymlinkSource ? "" : " validate=false";
		std::string desc = std::string("[symlink") + settingsCStr + "]\t" + fromPath + "\t" + linkPath + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool force = context->force;
	bool isSuccessful = context->dryRun;

	if(!context->dryRun)
	{
		int err = 0;

		if(validateSymlinkSource && !posix_path_exists_following_symlinks(fromPath))
		{
			err = errno;
			isSuccessful = false;
			force = false;
		}
		else
		{
			isSuccessful = (symlink(fromPath.c_str(), linkPath.c_str()) == 0);
			if(!isSuccessful)
			{
				err = errno;
			}
		}

		if(!isSuccessful && force)
		{
			if(!posix_remove_recursive(linkPath))
			{
				std::string parentPath = posix_parent_dir(linkPath);
				posix_mkdir_p(parentPath);
			}
			isSuccessful = (symlink(fromPath.c_str(), linkPath.c_str()) == 0);
			if(!isSuccessful)
			{
				err = errno;
			}
		}

		if(!isSuccessful)
		{
			std::string errStr = std::string("error: failed to create a symlink at \"") + linkPath + "\" referring to \"" + fromPath + "\". Error: " + strerror(err) + "\n";
			context->lastError.set(errStr, err != 0 ? err : 1);
			PrintToStdErr(context, std::move(errStr));
		}
	}
	return isSuccessful;
}
