#pragma once
#include "FileTree.h"
#include <atomic>
#include <functional>
#include <string>
#include <unordered_set>
#include <vector>

// Dependency-counting task node for concurrent scheduler execution.
// Lifetime is owned externally (e.g. unique_ptr vector in the caller);
// all graph edges (nextTasks, FileNode::producer) use raw pointers.
struct TaskProxy {
	std::function<void()> taskBlock;
	std::string stepActionName; // for error diagnostics only

	FileNode** inputs = nullptr;
	size_t inputCount = 0;
	FileNode** outputs = nullptr;
	size_t outputCount = 0;
	bool executed = false;

	// Decremented by each completing dependency; when it reaches 0 the task is dispatched.
	std::atomic<intptr_t> pendingDependenciesCount{0};

	// Tasks that must run after this one completes. Raw pointers — lifetime owned externally.
	std::unordered_set<TaskProxy*> nextTasks;

	// Glob pattern metadata for dependency analysis (see SchedulerMedusa)
	std::vector<std::string> globInputs;
	std::vector<std::string> globExclusiveInputs;
	std::vector<std::string> globMutatingInputs;
	std::vector<std::string> concreteMutatingPaths;
	std::vector<std::string> globOutputs;

	explicit TaskProxy(std::function<void()> task);
	~TaskProxy();

	TaskProxy(const TaskProxy&) = delete;
	TaskProxy& operator=(const TaskProxy&) = delete;

	// Called during single-threaded graph construction.
	void linkNextTask(TaskProxy* nextTask);

	// Called by linkNextTask (construction) and TaskScheduler (kick-off).
	void incrementDependencyCount();

	// Called by each completing dependency; dispatches executeTask when count reaches 0.
	void decrementDependencyCount();

	// Runs taskBlock, marks executed, then decrements all nextTasks.
	void executeTask();

	void describeTaskToStdErr() const;
};
