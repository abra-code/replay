#pragma once
#include "MedusaTaskProxy.h"
#include <unordered_set>
#include <vector>

struct OutputInfo {
	MedusaTaskProxy* producer = nullptr;
	std::unordered_set<MedusaTaskProxy*> consumers;
};

void IndexAllOutputsForRecursiveExecution(const std::vector<MedusaTaskProxy*>& allTasks,
                                          OutputInfo* outputInfoArray, size_t outputArrayCount);

void ConnectImplicitProducersForRecursiveExecution(FileNode* treeRoot);

std::unordered_set<MedusaTaskProxy*>
ConnectDynamicInputsForRecursiveExecution(const std::vector<MedusaTaskProxy*>& allTasks);

void ExecuteMedusaGraphRecursively(std::unordered_set<MedusaTaskProxy*> taskSet);

#if ENABLE_DEBUG_DUMP
void DumpRecursiveTaskTree(const std::unordered_set<MedusaTaskProxy*>& rootTaskSet);
#endif
