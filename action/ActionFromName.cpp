#include "ActionFromName.h"
#include "LogStream.h"
#include <optional>
#include <string_view>

Action
ActionFromName(std::optional<std::string_view> actionName, bool &isSrcDestAction)
{
	if(!actionName.has_value())
	{
		LogError("error: action not specified in a step.\n");
		isSrcDestAction = false;
		return kActionInvalid;
	}

	std::string_view sv = *actionName;
	Action replayAction = kActionInvalid;
	isSrcDestAction = false;

	if(sv == "clone" || sv == "copy")
	{
		replayAction = kFileActionClone;
		isSrcDestAction = true;
	}
	else if(sv == "move")
	{
		replayAction = kFileActionMove;
		isSrcDestAction = true;
	}
	else if(sv == "hardlink")
	{
		replayAction = kFileActionHardlink;
		isSrcDestAction = true;
	}
	else if(sv == "symlink")
	{
		replayAction = kFileActionSymlink;
		isSrcDestAction = true;
	}
	else if(sv == "create")
	{
		replayAction = kFileActionCreate;
		isSrcDestAction = false;
	}
	else if(sv == "delete")
	{
		replayAction = kFileActionDelete;
		isSrcDestAction = false;
	}
	else if(sv == "read")
	{
		replayAction = kFileActionRead;
		isSrcDestAction = false;
	}
	else if(sv == "list")
	{
		replayAction = kFileActionList;
		isSrcDestAction = false;
	}
	else if(sv == "tree")
	{
		replayAction = kFileActionTree;
		isSrcDestAction = false;
	}
	else if(sv == "info")
	{
		replayAction = kFileActionInfo;
		isSrcDestAction = false;
	}
	else if(sv == "glob")
	{
		replayAction = kFileActionGlob;
		isSrcDestAction = false;
	}
	else if(sv == "edit")
	{
		replayAction = kFileActionEdit;
		isSrcDestAction = false;
	}
	else if(sv == "execute")
	{
		replayAction = kActionExecuteTool;
		isSrcDestAction = false;
	}
	else if(sv == "echo")
	{
		replayAction = kActionEcho;
		isSrcDestAction = false;
	}
	else if(sv == "start")
	{
		replayAction = kActionStartServer;
		isSrcDestAction = false;
	}
	else if(sv == "wait")
	{
		replayAction = kActionWait;
		isSrcDestAction = false;
	}
	else
	{
		LogError("error: unrecognized step action: %.*s\n", (int)sv.size(), sv.data());
	}

	return replayAction;
}
