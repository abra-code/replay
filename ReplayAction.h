#import <Foundation/Foundation.h>
#include "FileTree/FileTree.h"

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
	kActionExecuteTool
} Action;


typedef struct
{
	NSDictionary<NSString *,NSString *> *environment;
	AtomicError *lastError;
	FileNode * __nullable fileTreeRoot;
	bool concurrent;
	bool verbose;
	bool dryRun;
	bool stopOnError;
	bool force;
} ReplayContext;

typedef void (^action_handler_t)(__nullable dispatch_block_t action,
								NSArray<NSString*> * __nullable inputs,
								NSArray<NSString*> * __nullable exclusiveInputs,
								NSArray<NSString*> * __nullable outputs);

void
HandleActionStep(NSDictionary *stepDescription, ReplayContext *context, action_handler_t actionHandler);

bool CloneItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, NSDictionary *actionSettings);
bool MoveItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, NSDictionary *actionSettings);
bool HardlinkItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, NSDictionary *actionSettings);
bool SymlinkItem(NSURL *fromURL, NSURL *linkURL, ReplayContext *context, NSDictionary *actionSettings);
bool CreateFile(NSURL *itemURL, NSString *content, ReplayContext *context, NSDictionary *actionSettings);
bool CreateDirectory(NSURL *itemURL, ReplayContext *context, NSDictionary *actionSettings);
bool DeleteItem(NSURL *itemURL, ReplayContext *context, NSDictionary *actionSettings);
bool ExcecuteTool(NSString *toolPath, NSArray<NSString*> *arguments, ReplayContext *context, NSDictionary *actionSettings);

NS_ASSUME_NONNULL_END
