#import <Foundation/Foundation.h>
#import "ReplayAction.h"

Action
ActionFromName(NSString *actionName, bool *isSrcDestActionPtr)
{
	if(actionName == nil)
	{
		fprintf(gLogErr, "error: action not specified in a step.\n");
		return kActionInvalid;
	}

	Action replayAction = kActionInvalid;
	bool isSrcDestAction = false;

	if([actionName isEqualToString:@"clone"] || [actionName isEqualToString:@"copy"])
	{
		replayAction = kFileActionClone;
		isSrcDestAction = true;
	}
	else if([actionName isEqualToString:@"move"])
	{
		replayAction = kFileActionMove;
		isSrcDestAction = true;
	}
	else if([actionName isEqualToString:@"hardlink"])
	{
		replayAction = kFileActionHardlink;
		isSrcDestAction = true;
	}
	else if([actionName isEqualToString:@"symlink"])
	{
		replayAction = kFileActionSymlink;
		isSrcDestAction = true;
	}
	else if([actionName isEqualToString:@"create"])
	{
		replayAction = kFileActionCreate;
		isSrcDestAction = false;
	}
	else if([actionName isEqualToString:@"delete"])
	{
		replayAction = kFileActionDelete;
		isSrcDestAction = false;
	}
	else if([actionName isEqualToString:@"execute"])
	{
		replayAction = kActionExecuteTool;
		isSrcDestAction = false;
	}
	else if([actionName isEqualToString:@"echo"])
	{
		replayAction = kActionEcho;
		isSrcDestAction = false;
	}
	else if([actionName isEqualToString:@"start"])
	{
		replayAction = kActionStartServer;
		isSrcDestAction = false;
	}
	else if([actionName isEqualToString:@"wait"])
	{
		replayAction = kActionWait;
		isSrcDestAction = false;
	}
	else
	{
		replayAction = kActionInvalid;
		fprintf(gLogErr, "error: unrecognized step action: %s\n", [actionName UTF8String]);
	}

	*isSrcDestActionPtr = isSrcDestAction;
	return replayAction;
}

