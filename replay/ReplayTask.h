#pragma once
#include "ReplayAction.h"
#include "FileTree.h"
#include <vector>

void DispatchTasksConcurrentlyWithDependencyAnalysis(const std::vector<ActionStep>& playlist, ReplayContext *context);
