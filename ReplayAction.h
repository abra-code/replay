#import <Foundation/Foundation.h>
#include "FileTree/FileTree.h"
#import "OutputSerializer.h"

NS_ASSUME_NONNULL_BEGIN

@interface AtomicError : NSObject
	@property(atomic, strong) NSError *error;
@end


typedef enum
{
	kActionInvalid,
	kFileActionClone,
	kFileActionMove,
	kFileActionHardlink,
	kFileActionSymlink,
	kFileActionCreate,
	kFileActionDelete,
	kActionExecuteTool,
	kActionEcho
} Action;


typedef struct
{
	NSDictionary<NSString *,NSString *> *environment;
	AtomicError *lastError;
	FileNode * __nullable fileTreeRoot;
	OutputSerializer *__nullable outputSerializer; //not used in serial execution
	dispatch_queue_t queue; //not used for execution with dependency analysis
	dispatch_group_t group; //not used for execution with dependency analysis
	NSInteger actionCounter; //counter incremented with each serially created action
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
