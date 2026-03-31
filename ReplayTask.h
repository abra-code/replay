#import "TaskProxy.h"
#import "ReplayAction.h"
#include "FileTree/FileTree.h"

#ifdef __cplusplus
extern "C" {
#endif

void DispatchTasksConcurrentlyWithDependencyAnalysis(NSArray<NSDictionary*> *playlist, ReplayContext *context);

NSArray<TaskProxy *> *
TasksFromStep(NSDictionary *replayStep, ReplayContext *context);

#ifdef __cplusplus
}
#endif
