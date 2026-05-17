#import "TaskProxy.h"
#import "ReplayAction.h"
#include "FileTree.h"
#include <vector>

void DispatchTasksConcurrentlyWithDependencyAnalysis(const std::vector<ActionStep>& playlist, ReplayContext *context);

NSArray<TaskProxy *> *
TasksFromStep(const ActionStep& step, ReplayContext *context);
