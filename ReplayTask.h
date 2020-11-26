#import "TaskProxy.h"
#import "ReplayAction.h"
#include "FileTree/FileTree.h"

void DispatchTasksConcurrentlyWithDependencyAnalysis(NSArray<NSDictionary*> *playlist, ReplayContext *context);

NSArray<TaskProxy *> *
TasksFromStep(NSDictionary *replayStep, ReplayContext *context);
