#import <Foundation/Foundation.h>
#include "FileTree/FileTree.h"
#import "OutputSerializer.h"

NS_ASSUME_NONNULL_BEGIN

@interface AtomicError : NSObject
	@property(atomic, strong) NSError *error;
@end


typedef enum
{
	kActionInvalid = 0,
	kFileActionClone,
	kFileActionMove,
	kFileActionHardlink,
	kFileActionSymlink,
	kFileActionCreate,
	kFileActionDelete,
	kActionExecuteTool,
	kActionEcho,
	kActionStartServer, // the following are only valid for "dispatch" tool
	kActionWait         // not a real action
} Action;


typedef struct
{
	NSDictionary<NSString *,NSString *> *environment;
	AtomicError *lastError;
	FileNode * __nullable fileTreeRoot;
	OutputSerializer *__nullable outputSerializer; //not used in serial execution
	dispatch_queue_t queue; // used only for serial execution
	intptr_t councurrencyLimit; //maximum number of tasks allowed to be executed concurrently. 0 = unlimited
	NSInteger actionCounter; //counter incremented with each serially created action
	NSString *batchName; //when running in server mode the batch name is provided for unique message port name
	CFMessagePortRef callbackPort; //the port to report back progress status and finish event
	bool concurrent;
	bool analyzeDependencies;
	bool verbose;
	bool dryRun;
	bool stopOnError;
	bool force;
	bool orderedOutput;
} ReplayContext;

typedef struct
{
	NSDictionary *settings;
	NSInteger index;
} ActionContext;

typedef void (^action_handler_t)(__nullable dispatch_block_t action,
								NSArray<NSString*> * __nullable inputs,
								NSArray<NSString*> * __nullable exclusiveInputs,
								NSArray<NSString*> * __nullable outputs);

Action ActionFromName(NSString *actionName, bool *isSrcDestActionPtr);
NSDictionary * ActionDescriptionFromLine(const char *line, ssize_t linelen);
void HandleActionStep(NSDictionary *stepDescription, ReplayContext *context, action_handler_t actionHandler);

bool CloneItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, ActionContext *actionContext);
bool MoveItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, ActionContext *actionContext);
bool HardlinkItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, ActionContext *actionContext);
bool SymlinkItem(NSURL *fromURL, NSURL *linkURL, ReplayContext *context, ActionContext *actionContext);
bool CreateFile(NSURL *itemURL, NSString *content, ReplayContext *context, ActionContext *actionContext);
bool CreateDirectory(NSURL *itemURL, ReplayContext *context, ActionContext *actionContext);
bool DeleteItem(NSURL *itemURL, ReplayContext *context, ActionContext *actionContext);
bool ExcecuteTool(NSString *toolPath, NSArray<NSString*> *arguments, ReplayContext *context, ActionContext *actionContext);
bool Echo(NSString *content, ReplayContext *context, ActionContext *actionContext);

NS_ASSUME_NONNULL_END
