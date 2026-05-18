#import "ReplayTask.h"
#import "TaskProxyGlob.h"
#import "SchedulerMedusa.h"
#import "TaskScheduler.h"
#include "GlobOverlap.h"
#include "ReplaySignpost.h"
#include <algorithm>
#include <memory>


static inline FileNode * FileNodeFromPath(FileNode *fileTreeRoot, const std::string &path, TaskProxy* producer, bool isExclusiveInput)
{
	std::string lowercasePath = path;
	std::transform(lowercasePath.begin(), lowercasePath.end(), lowercasePath.begin(), ::tolower);
	FileNode *outNode = FindOrInsertFileNodeForPath(fileTreeRoot, lowercasePath.c_str());
	//Input nodes don't have a producer.
	//important not to reset to NULL to not override what might have been set already
	if(producer != nil)
	{
		if(outNode->producer != NULL)
		{
			LogError("error: invalid playlist for concurrent execution.\n"
				"The output path: \"%s\"\n"
				"is specified as a product of two or more actions.\n"
				"See \"replay --help\" for more information about concurrent execution constraints.\n", path.c_str());
			safe_exit(EXIT_FAILURE);
		}
		outNode->producer = (__bridge void *)producer;
	}
	else
	{//it is a consumer's request
		if(isExclusiveInput)
			outNode->isExclusiveInput = 1;

		if((outNode->isExclusiveInput != 0) && (outNode->hasConsumer != 0))
		{//this input is marked as exclusive and now we are adding a second consumer. This is not allowed
			LogError("error: invalid playlist for concurrent execution.\n"
				"The path: \"%s\"\n"
				"is specified as an exclusive input for one action (like move or delete) but\n"
				"there is more than one action consuming it.\n"
				"See \"replay --help\" for more information about exclusive inputs.\n", path.c_str());
			safe_exit(EXIT_FAILURE);
		}

		outNode->hasConsumer = 1;
	}

	return outNode;
}

NSArray<TaskProxy *> *
TasksFromStep(const ActionStep& step, ReplayContext *context)
{
	if(context->stopOnError && (context->lastError.hasError()))
		return nil;

	NSMutableArray<TaskProxy *> *tasksFromStep = [NSMutableArray arrayWithCapacity:0];

	HandleActionStep(step, context,
		[&tasksFromStep, &step, context](
			std::function<void()> action,
			std::vector<std::string> inputs,
			std::vector<std::string> mutatingInputs,
			std::vector<std::string> exclusiveInputs,
			std::vector<std::string> outputs)
		{
			if(!action)
				return;

			dispatch_block_t block = ^{ action(); };
			TaskProxy *oneTask = [[TaskProxy alloc] initWithTask:block];
			{
				auto actionName = step.string_value("action");
				oneTask.stepActionName = actionName.has_value() ? @(actionName->c_str()) : nil;
			}
			[tasksFromStep addObject:oneTask];

			// Classify each input/output path: glob patterns go to TaskProxy's glob properties
			// for later overlap-based dependency analysis; concrete paths go into the FileTree
			// as before for exact node-based dependency tracking.

			std::vector<std::string> globInputList;
			std::vector<std::string> globExclusiveInputList;
			std::vector<std::string> globMutatingInputList;
			std::vector<std::string> concreteMutatingPathList;

			size_t totalInputCount = inputs.size() + exclusiveInputs.size();
			// Allocate for worst case (all concrete); actual count may be smaller
			std::unique_ptr<FileNode*, decltype(&free)> inputOwner(
				totalInputCount > 0 ? (FileNode**)malloc(sizeof(FileNode*) * totalInputCount) : nullptr, free);
			FileNode** inputList = inputOwner.get();

			size_t concreteInputIndex = 0;
			for(const auto& oneInput : inputs)
			{
				if(globoverlap::is_glob_pattern(oneInput))
				{
					// Lowercase to match GetPathForNode output (FileTree stores lowercased
					// paths); concrete_matches_glob compares them case-sensitively.
					std::string lowerPath = oneInput;
					std::transform(lowerPath.begin(), lowerPath.end(), lowerPath.begin(), ::tolower);
					globInputList.push_back(std::move(lowerPath));
				}
				else
				{
					inputList[concreteInputIndex] = FileNodeFromPath(context->fileTreeRoot, oneInput, nil, false);
					concreteInputIndex++;
				}
			}

			for(const auto& oneInput : exclusiveInputs)
			{
				if(globoverlap::is_glob_pattern(oneInput))
				{
					std::string lowerPath = oneInput;
					std::transform(lowerPath.begin(), lowerPath.end(), lowerPath.begin(), ::tolower);
					globExclusiveInputList.push_back(std::move(lowerPath));
				}
				else
				{
					inputList[concreteInputIndex] = FileNodeFromPath(context->fileTreeRoot, oneInput, nil, true);
					concreteInputIndex++;
				}
			}

			for(const auto& oneInput : mutatingInputs)
			{
				if(globoverlap::is_glob_pattern(oneInput))
				{
					std::string lowerPath = oneInput;
					std::transform(lowerPath.begin(), lowerPath.end(), lowerPath.begin(), ::tolower);
					globMutatingInputList.push_back(std::move(lowerPath));
					continue;
				}

				// Concrete mutating path. ConnectGlobDependencies handles producer
				// and consumer chaining uniformly via concreteMutatingPaths and
				// playlist-order Pass B; the FileNode is inserted here for the
				// exclusive-input collision check, the parent-walk in
				// ConnectImplicitProducers (which links a parent dir's producer
				// to the mutator), and to chain a prior playlist producer that
				// only exists as a tree-walk ancestor (e.g. clone of an enclosing
				// directory whose contents have no per-file producer task).
				std::string lowercasePath = oneInput;
				std::transform(lowercasePath.begin(), lowercasePath.end(), lowercasePath.begin(), ::tolower);
				FileNode *node = FindOrInsertFileNodeForPath(context->fileTreeRoot, lowercasePath.c_str());

				if(node->isExclusiveInput != 0)
				{
					LogError("error: invalid playlist for concurrent execution.\n"
						"The path: \"%s\"\n"
						"is specified as a mutating input (e.g. edit) but another action has marked it\n"
						"as an exclusive input (delete or move). These cannot apply to the same path.\n"
						"See \"replay --help\" for more information.\n", oneInput.c_str());
					safe_exit(EXIT_FAILURE);
				}

				// Conditional FileTree producer-replacement: only when no prior
				// consumer has registered this path. Without prior consumers the
				// FileTree edge mutator -> next-consumer is the right direction;
				// with prior consumers, that edge would conflict with Pass B's
				// pre-mutation reader edge (consumer -> mutator), creating a
				// cycle. Skipping the replacement in that case lets Pass B
				// handle ordering on both sides per playlist position.
				if(node->hasConsumer == 0)
				{
					node->producer = (__bridge void *)oneTask;
				}

				// Lowercase posix path so concrete-vs-concrete and concrete-vs-glob
				// comparisons in ConnectGlobDependencies match GetPathForNode output.
				concreteMutatingPathList.push_back(std::move(lowercasePath));
			}

			if(concreteInputIndex > 0)
			{
				oneTask.inputCount = concreteInputIndex;
				oneTask.inputs = inputOwner.release();
			}

			[oneTask setGlobInputs:std::move(globInputList)];
			[oneTask setGlobExclusiveInputs:std::move(globExclusiveInputList)];
			[oneTask setGlobMutatingInputs:std::move(globMutatingInputList)];
			[oneTask setConcreteMutatingPaths:std::move(concreteMutatingPathList)];

			std::vector<std::string> globOutputList;

			if(!outputs.empty())
			{
				std::unique_ptr<FileNode*, decltype(&free)> outputOwner(
					(FileNode**)malloc(sizeof(FileNode*) * outputs.size()), free);
				FileNode** outputList = outputOwner.get();
				size_t concreteOutputIndex = 0;
				for(const auto& oneOutput : outputs)
				{
					if(globoverlap::is_glob_pattern(oneOutput))
					{
						std::string lowerPath = oneOutput;
						std::transform(lowerPath.begin(), lowerPath.end(), lowerPath.begin(), ::tolower);
						globOutputList.push_back(std::move(lowerPath));
					}
					else
					{
						outputList[concreteOutputIndex] = FileNodeFromPath(context->fileTreeRoot, oneOutput, oneTask, false);
						concreteOutputIndex++;
					}
				}
				if(concreteOutputIndex > 0)
				{
					oneTask.outputCount = concreteOutputIndex;
					oneTask.outputs = outputOwner.release();
				}
			}

			[oneTask setGlobOutputs:std::move(globOutputList)];
		});

	return tasksFromStep;
}


static inline void
ExecuteTasksWithScheduler(NSArray<TaskProxy*> *allTasks, ReplayContext *context, NSUInteger inputCount, NSUInteger outputCount)
{
	ConnectImplicitProducers(context->fileTreeRoot);

	// Connect dependencies from glob patterns (glob↔glob via NFA product,
	// concrete↔glob via glob_match). Must run before dynamic input connection
	// so that glob-based dependencies are in place for scheduling.
	ConnectGlobDependencies(allTasks);

	TaskScheduler *scheduler = [[TaskScheduler alloc] initWithConcurrencyLimit:context->councurrencyLimit];

	//graph root task is created by the scheduler
	//we build the graph by adding children tasks to the root

	ConnectDynamicInputsForScheduler(allTasks, //input list of all raw unconnected medusas
									scheduler.rootTask);

	REPLAY_SIGNPOST_BEGIN("SchedulerExecution", "task_count=%lu", (unsigned long)[allTasks count]);
	[scheduler startExecutionAndWait];
	REPLAY_SIGNPOST_END("SchedulerExecution");
}

static inline void
VerifyAllTasksExecuted(NSArray<TaskProxy*> *allTasks)
{
	BOOL atLeastOneNotExecuted = NO;
	for(__unsafe_unretained TaskProxy* oneTask in allTasks)
	{
		if(!oneTask.executed)
		{
			if(atLeastOneNotExecuted == NO)
			{ //the first one we encountered
				LogError("error: not all tasks have been executed.\n"
				"Most likely there are circular dependencies in the action tree.\n"
				"See \"replay --help\" for more information about action graph restictions.\n"
				"Not executed tasks:\n"
				);
				atLeastOneNotExecuted = YES;
			}
			[oneTask describeTaskToStdErr];
		}
	}

	if(atLeastOneNotExecuted)
	{
		safe_exit(EXIT_FAILURE);
	}
}

void
DispatchTasksConcurrentlyWithDependencyAnalysis(const std::vector<ActionStep>& playlist, ReplayContext *context)
{
	assert(context->concurrent);
	DeleteFileTree(context->fileTreeRoot);
	context->fileTreeRoot = CreateFileTreeRoot();

    NSMutableArray<TaskProxy*> *taskList = [[NSMutableArray alloc] initWithCapacity:0];
	NSUInteger totalInputCount = 0;
	NSUInteger totalOutputCount = 0;

	REPLAY_SIGNPOST_BEGIN("TaskProxyBuild", "playlist_count=%zu", playlist.size());

	for (const auto& step : playlist)
	{
		NSArray<TaskProxy *> *stepTasks = TasksFromStep(step, context);
		for(TaskProxy *oneTask in stepTasks)
		{
			[taskList addObject:oneTask];
			totalInputCount += oneTask.inputCount;
			totalOutputCount += oneTask.outputCount;
		}
	}

	REPLAY_SIGNPOST_END("TaskProxyBuild");

	// at that point the whole input and output paths tree is already constructed
	// with all explicit producers referred in their respective nodes

	ExecuteTasksWithScheduler(taskList, context, totalInputCount, totalOutputCount);

	// Post-execution verification
	// in case of circular dependencies some tasks were not scheduled for execution
	// because their dependencies have not been satisifed (the dependency counter never dropped to 0)
	VerifyAllTasksExecuted(taskList);
	REPLAY_PRINT_TIMINGS();
}
