#import "TaskProxy.h"
#import "ReplayAction.h"
#include "FileTree/FileTree.h"

void ExecuteTasksConcurrently(NSArray<NSDictionary*> *playlist, ReplayContext *context);

NSArray<TaskProxy *> *
TasksFromStep(NSDictionary *replayStep, ReplayContext *context);
