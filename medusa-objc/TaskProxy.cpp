#include "TaskProxy.h"
#include "AsyncDispatch.h"
#include "LogStream.h"
#include <cassert>
#include <cstdlib>

//#define TRACE_PROXY 1

TaskProxy::TaskProxy(std::function<void()> task)
	: taskBlock(std::move(task))
{
#if TRACE_PROXY
	printf("init proxy = %p\n", this);
#endif
}

TaskProxy::~TaskProxy()
{
#if TRACE_PROXY
	printf("dealloc proxy = %p\n", this);
#endif
	free(inputs);
	free(outputs);
}

void TaskProxy::linkNextTask(TaskProxy* nextTask)
{
	assert(nextTask != nullptr);
	// Linking self would create a self-loop: this task would never dispatch.
	if(nextTask == this)
		return;

	// insert() returns {iterator, inserted}; only increment if truly new.
	auto [it, inserted] = nextTasks.insert(nextTask);
	if(inserted)
		nextTask->incrementDependencyCount();
}

void TaskProxy::incrementDependencyCount()
{
	pendingDependenciesCount.fetch_add(1, std::memory_order_relaxed);
}

// A task may have multiple dependencies, each incrementing the counter during
// graph construction. As each one completes it calls decrementDependencyCount.
// When the counter reaches 0, all dependencies are satisfied and we dispatch.
void TaskProxy::decrementDependencyCount()
{
	// fetch_sub returns the value BEFORE subtraction.
	intptr_t prev = pendingDependenciesCount.fetch_sub(1, std::memory_order_acq_rel);
	assert(prev > 0); // programmer error if it goes below 0
	if(prev == 1)
	{// all dependencies satisfied — dispatch this task for execution
		AsyncDispatch([this]() { executeTask(); });
	}
}

void TaskProxy::executeTask()
{
#if TRACE_PROXY
	printf("executing proxy = %p\n", this);
#endif

	// No task in the graph may execute more than once.
	assert(!executed);

	taskBlock();
	executed = true;
	taskBlock = nullptr; // release captured upvalues immediately (matches GCD block semantics)

	// Signal all downstream tasks that one more dependency is satisfied.
	for(TaskProxy* nextTask : nextTasks)
		nextTask->decrementDependencyCount();
}

void TaskProxy::describeTaskToStdErr() const
{
	char path[2048];
	LogError("[%s]\n", stepActionName.empty() ? "unknown" : stepActionName.c_str());
	LogError("  unsatisfied dependency count: %ld\n", (long)pendingDependenciesCount.load());

	LogError("  inputs:\n");
	for(size_t i = 0; i < inputCount; i++)
	{
		GetPathForNode(inputs[i], path, sizeof(path));
		LogError("    %s\n", path);
	}

	LogError("  outputs:\n");
	for(size_t i = 0; i < outputCount; i++)
	{
		GetPathForNode(outputs[i], path, sizeof(path));
		LogError("    %s\n", path);
	}
}

#if ENABLE_DEBUG_DUMP
void TaskProxy::dumpDescription() const
{
	printf("TaskProxy self=%p\n", this);

	printf("  inputs:\n");
	for(size_t i = 0; i < inputCount; i++)
	{
		printf("    ");
		DumpBranchForNode(inputs[i]);
	}

	printf("  outputs:\n");
	for(size_t i = 0; i < outputCount; i++)
	{
		printf("    ");
		DumpBranchForNode(outputs[i]);
	}
}
#endif
