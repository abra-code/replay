#pragma once
#include "TaskProxy.h"
#include <vector>

void ConnectImplicitProducers(FileNode* treeRoot);

void ConnectDynamicInputsForScheduler(const std::vector<TaskProxy*>& allTasks,
                                      TaskProxy* rootTask);

void ConnectGlobDependencies(const std::vector<TaskProxy*>& allTasks);
