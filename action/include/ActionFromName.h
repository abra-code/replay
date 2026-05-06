#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

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
	kActionExecuteTool,
	kActionEcho,
	kActionStartServer, // the following are only valid for "dispatch" tool
	kActionWait         // not a real action
} Action;

Action ActionFromName(NSString *actionName, bool *isSrcDestActionPtr);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
