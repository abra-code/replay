#pragma once
#include <optional>
#include <string_view>

typedef enum
{
	kActionInvalid = 0,
	kFileActionClone,
	kFileActionMove,
	kFileActionHardlink,
	kFileActionSymlink,
	kFileActionCreate,
	kFileActionDelete,
	kFileActionRead,
	kFileActionList,
	kFileActionTree,
	kFileActionInfo,
	kFileActionGlob,
	kFileActionEdit,
	kActionExecuteTool,
	kActionEcho,
	kActionStartServer, // the following are only valid for "dispatch" tool
	kActionWait         // not a real action
} Action;

Action ActionFromName(std::optional<std::string_view> actionName, bool &isSrcDestAction);
