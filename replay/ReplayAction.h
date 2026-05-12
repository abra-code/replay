#import <Foundation/Foundation.h>
#include "FileTree.h"
#include "LogStream.h"

#ifdef __cplusplus
class OutputSerializer;
#endif

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

@interface AtomicError : NSObject
	@property(atomic, strong, direct) NSError *error;
@end

typedef struct
{
	NSDictionary<NSString *,NSString *> *environment;
	AtomicError *lastError;
	FileNode * __nullable fileTreeRoot;
	OutputSerializer* outputSerializer; // always non-null during execution
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
								NSArray<NSString*> * __nullable mutatingInputs,
								NSArray<NSString*> * __nullable exclusiveInputs,
								NSArray<NSString*> * __nullable outputs);

NSDictionary * ActionDescriptionFromLine(const char *line, ssize_t linelen);
void HandleActionStep(NSDictionary *stepDescription, ReplayContext *context, action_handler_t actionHandler);

bool CloneItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, ActionContext *actionContext);
bool MoveItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, ActionContext *actionContext);
bool HardlinkItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, ActionContext *actionContext);
bool SymlinkItem(NSURL *fromURL, NSURL *linkURL, ReplayContext *context, ActionContext *actionContext);
bool CreateFile(NSURL *itemURL, NSString *content, ReplayContext *context, ActionContext *actionContext);
bool CreateFileFromBlob(NSURL *itemURL, NSString *base64Content, ReplayContext *context, ActionContext *actionContext);
bool CreateDirectory(NSURL *itemURL, ReplayContext *context, ActionContext *actionContext);
bool DeleteItem(NSURL *itemURL, ReplayContext *context, ActionContext *actionContext);
bool ReadFile(const char *filePath, ReplayContext *context, ActionContext *actionContext);
bool ListDirectory(const char *dirPath, ReplayContext *context, ActionContext *actionContext);
bool DirectoryTree(const char *dirPath, NSInteger maxDepth, ReplayContext *context, ActionContext *actionContext);
bool GetFileInfo(const char *path, ReplayContext *context, ActionContext *actionContext);
bool GlobFiles(NSString *rootDir, NSArray<NSString*> *globPatterns, NSArray<NSString*> *excludePatterns, NSInteger maxResults, ReplayContext *context, ActionContext *actionContext);
// edits: array of dicts with keys: oldText (required), newText, limit (default 1, 0=unlimited), regex, case-insensitive
// actionDryRun: show plan without writing (overrides nothing; stacks with context->dryRun)
bool EditFile(const char *filePath, NSArray<NSDictionary *> *edits, bool actionDryRun, ReplayContext *context, ActionContext *actionContext);
bool ExcecuteTool(NSString *toolPath, NSArray<NSString*> *arguments, ReplayContext *context, ActionContext *actionContext);
bool Echo(NSString *content, ReplayContext *context, ActionContext *actionContext);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
