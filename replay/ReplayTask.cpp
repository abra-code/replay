#include "ReplayTask.h"
#include "TaskCache.h"
#include "TaskProxy.h"
#include "TaskScheduler.h"
#include "SchedulerMedusa.h"
#include "GlobOverlap.h"
#include "ReplaySignpost.h"
#include <algorithm>
#include <cassert>
#include <memory>


static inline FileNode* FileNodeFromPath(FileNode* fileTreeRoot, const std::string& path,
                                         TaskProxy* producer, bool isExclusiveInput)
{
	std::string lowercasePath = path;
	std::transform(lowercasePath.begin(), lowercasePath.end(), lowercasePath.begin(), ::tolower);
	FileNode* outNode = FindOrInsertFileNodeForPath(fileTreeRoot, lowercasePath.c_str());

	if(producer != nullptr)
	{
		if(outNode->producer != nullptr)
		{
			LogError("error: invalid playlist for concurrent execution.\n"
				"The output path: \"%s\"\n"
				"is specified as a product of two or more actions.\n"
				"See \"replay --help\" for more information about concurrent execution constraints.\n", path.c_str());
			safe_exit(EXIT_FAILURE);
		}
		outNode->producer = producer; // raw TaskProxy* stored as void*
	}
	else
	{
		if(isExclusiveInput)
			outNode->isExclusiveInput = 1;

		if((outNode->isExclusiveInput != 0) && (outNode->hasConsumer != 0))
		{
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


// Builds TaskProxy objects from one action step and appends them to the output collections.
// ownedTasks is the lifetime owner; rawList is the non-owning view used by the scheduler.
static void TasksFromStep(const ActionStep& step, ReplayContext* context,
                          std::vector<std::unique_ptr<TaskProxy>>& ownedTasks,
                          std::vector<TaskProxy*>& rawList)
{
	if(context->stopOnError && context->lastError.hasError())
		return;

	HandleActionStep(step, context,
		[&ownedTasks, &rawList, &step, context](
			std::function<bool()> action,
			std::vector<std::string> inputs,
			std::vector<std::string> mutatingInputs,
			std::vector<std::string> exclusiveInputs,
			std::vector<std::string> outputs,
			ActionCacheInfo cacheInfo)
		{
			if(!action)
				return;

			std::string actionName = step.string_value("action").value_or(std::string());

			std::function<void()> taskBlock;
			CacheSession *session = context->cacheSession;
			if((session != nullptr) && cacheInfo.cacheable)
			{
				// Signature and env text come from the expanded, original-case declaration
				// vectors, before the FileTree makes its lowercased copies below, so the
				// cache key stays independent of dependency-analysis internals.
				std::vector<std::string> signatureEnvNames = context->cacheGlobalEnvNames;
				signatureEnvNames.insert(signatureEnvNames.end(), cacheInfo.envNames.begin(), cacheInfo.envNames.end());
				std::string signature = compute_task_signature(actionName, inputs, exclusiveInputs, mutatingInputs, outputs,
					cacheInfo.extras, signatureEnvNames, context->playlistKey);
				std::string envText = build_cache_env_text(context->cacheGlobalEnvNames, cacheInfo.envNames, context->environment);

				// Owned paths (world_out material): outputs + exclusive + mutating, glob or
				// concrete. Concrete outputs separately for the fast existence pass.
				std::vector<std::string> ownedPaths = outputs;
				ownedPaths.insert(ownedPaths.end(), exclusiveInputs.begin(), exclusiveInputs.end());
				ownedPaths.insert(ownedPaths.end(), mutatingInputs.begin(), mutatingInputs.end());

				std::vector<std::string> concreteOutputs;
				for(const auto& oneOutput : outputs)
				{
					if(!globoverlap::is_glob_pattern(oneOutput))
						concreteOutputs.push_back(oneOutput);
				}

				TaskCacheRecord *record = session->make_record(std::move(signature), actionName, inputs,
					std::move(ownedPaths), std::move(concreteOutputs), std::move(envText), cacheInfo.outputsExistenceOnly);
				taskBlock = [session, record, inner = std::move(action)]() {
					session->run_task(record, inner);
				};
			}
			else
			{
				taskBlock = [inner = std::move(action)]() {
					(void)inner();
				};
			}

			auto oneTask = std::make_unique<TaskProxy>(std::move(taskBlock));
			oneTask->stepActionName = actionName;

			TaskProxy* taskPtr = oneTask.get();
			rawList.push_back(taskPtr);
			ownedTasks.push_back(std::move(oneTask));

			// Classify paths: glob patterns go to TaskProxy's glob vectors for
			// overlap-based dependency analysis; concrete paths go into the FileTree
			// for exact node-based dependency tracking.

			std::vector<std::string> globInputList;
			std::vector<std::string> globExclusiveInputList;
			std::vector<std::string> globMutatingInputList;
			std::vector<std::string> concreteMutatingPathList;

			size_t totalInputCount = inputs.size() + exclusiveInputs.size();
			std::unique_ptr<FileNode*, decltype(&free)> inputOwner(
				totalInputCount > 0 ? (FileNode**)malloc(sizeof(FileNode*) * totalInputCount) : nullptr, free);
			FileNode** inputList = inputOwner.get();

			size_t concreteInputIndex = 0;
			for(const auto& oneInput : inputs)
			{
				if(globoverlap::is_glob_pattern(oneInput))
				{
					std::string lowerPath = oneInput;
					std::transform(lowerPath.begin(), lowerPath.end(), lowerPath.begin(), ::tolower);
					globInputList.push_back(std::move(lowerPath));
				}
				else
				{
					inputList[concreteInputIndex] = FileNodeFromPath(context->fileTreeRoot, oneInput, nullptr, false);
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
					inputList[concreteInputIndex] = FileNodeFromPath(context->fileTreeRoot, oneInput, nullptr, true);
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
				// only exists as a tree-walk ancestor.
				std::string lowercasePath = oneInput;
				std::transform(lowercasePath.begin(), lowercasePath.end(), lowercasePath.begin(), ::tolower);
				FileNode* node = FindOrInsertFileNodeForPath(context->fileTreeRoot, lowercasePath.c_str());

				if(node->isExclusiveInput != 0)
				{
					LogError("error: invalid playlist for concurrent execution.\n"
						"The path: \"%s\"\n"
						"is specified as a mutating input (e.g. edit) but another action has marked it\n"
						"as an exclusive input (delete or move). These cannot apply to the same path.\n"
						"See \"replay --help\" for more information.\n", oneInput.c_str());
					safe_exit(EXIT_FAILURE);
				}

				// Conditional producer-replacement: only when no prior consumer has registered
				// this path. With prior consumers, the Pass B edge handles ordering instead.
				if(node->hasConsumer == 0)
					node->producer = taskPtr; // raw TaskProxy* as void*

				concreteMutatingPathList.push_back(std::move(lowercasePath));
			}

			if(concreteInputIndex > 0)
			{
				taskPtr->inputCount = concreteInputIndex;
				taskPtr->inputs = inputOwner.release();
			}

			taskPtr->globInputs          = std::move(globInputList);
			taskPtr->globExclusiveInputs = std::move(globExclusiveInputList);
			taskPtr->globMutatingInputs  = std::move(globMutatingInputList);
			taskPtr->concreteMutatingPaths = std::move(concreteMutatingPathList);

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
						taskPtr->globOutputs.push_back(std::move(lowerPath));
					}
					else
					{
						outputList[concreteOutputIndex] = FileNodeFromPath(context->fileTreeRoot, oneOutput, taskPtr, false);
						concreteOutputIndex++;
					}
				}
				if(concreteOutputIndex > 0)
				{
					taskPtr->outputCount = concreteOutputIndex;
					taskPtr->outputs = outputOwner.release();
				}
			}
		});
}


static inline void
ExecuteTasksWithScheduler(const std::vector<TaskProxy*>& allTasks, ReplayContext* context)
{
	ConnectImplicitProducers(context->fileTreeRoot);

	// Connect glob-based dependencies before dynamic input connection so that
	// glob edges are in place for scheduling.
	ConnectGlobDependencies(allTasks);

	TaskScheduler scheduler(context->councurrencyLimit);
	ConnectDynamicInputsForScheduler(allTasks, scheduler.rootTask());

	REPLAY_SIGNPOST_BEGIN("SchedulerExecution", "task_count=%zu", allTasks.size());
	scheduler.startExecutionAndWait();
	REPLAY_SIGNPOST_END("SchedulerExecution");
}

static inline void
VerifyAllTasksExecuted(const std::vector<TaskProxy*>& allTasks)
{
	bool atLeastOneNotExecuted = false;
	for(TaskProxy* oneTask : allTasks)
	{
		if(!oneTask->executed)
		{
			if(!atLeastOneNotExecuted)
			{
				LogError("error: not all tasks have been executed.\n"
					"Most likely there are circular dependencies in the action tree.\n"
					"See \"replay --help\" for more information about action graph restrictions.\n"
					"Not executed tasks:\n");
				atLeastOneNotExecuted = true;
			}
			oneTask->describeTaskToStdErr();
		}
	}

	if(atLeastOneNotExecuted)
		safe_exit(EXIT_FAILURE);
}

void
DispatchTasksConcurrentlyWithDependencyAnalysis(const std::vector<ActionStep>& playlist, ReplayContext* context)
{
	assert(context->concurrent);
	DeleteFileTree(context->fileTreeRoot);
	context->fileTreeRoot = CreateFileTreeRoot();

	// The cache session owns every TaskCacheRecord and the manifest for the duration
	// of this playlist. One session per --playlist-key: pruning is scoped to the key
	// it processed, so entries belonging to other keys are carried through untouched.
	// MUST be declared before ownedTasks: from stage 4 the task blocks capture record
	// pointers, so the tasks have to be destroyed before the records they point at.
	std::unique_ptr<CacheSession> cacheSession;
	if(context->cacheEnabled && !context->playlistPath.empty())
	{
		cacheSession = std::make_unique<CacheSession>(context->playlistPath, context->playlistKey, context);
		cacheSession->load();
		context->cacheSession = cacheSession.get();
		if(context->verbose)
		{
			LogError("cache: loaded %zu entries from %s\n",
				cacheSession->loaded_entry_count(), cacheSession->manifest_path().c_str());
		}
	}

	std::vector<std::unique_ptr<TaskProxy>> ownedTasks; // lifetime owner
	std::vector<TaskProxy*> taskList;                   // non-owning view for scheduler

	size_t totalInputCount = 0;
	size_t totalOutputCount = 0;

	REPLAY_SIGNPOST_BEGIN("TaskProxyBuild", "playlist_count=%zu", playlist.size());

	for(const auto& step : playlist)
	{
		size_t prevSize = taskList.size();
		TasksFromStep(step, context, ownedTasks, taskList);
		for(size_t i = prevSize; i < taskList.size(); i++)
		{
			totalInputCount  += taskList[i]->inputCount;
			totalOutputCount += taskList[i]->outputCount;
		}
	}

	REPLAY_SIGNPOST_END("TaskProxyBuild");

	if(cacheSession != nullptr)
	{
		// TasksFromStep returns immediately once an error is set under --stop-on-error,
		// including declaration-time errors such as an undefined ${VAR}, so the tail of
		// the playlist may never have been examined. Entries for those steps must not be
		// mistaken for entries of removed steps and pruned.
		bool buildComplete = !(context->stopOnError && context->lastError.hasError());
		cacheSession->set_prune_allowed(buildComplete);
	}

	ExecuteTasksWithScheduler(taskList, context);

	// Note: VerifyAllTasksExecuted calls safe_exit on a dependency cycle, so finalize
	// below does not run in that case. That is safe - every entry is simply carried
	// forward untouched - but it does mean a cycle discards the completed prefix.
	VerifyAllTasksExecuted(taskList);

	// Finalize after the scheduler has drained, and even when lastError is set or
	// --stop-on-error truncated the run: the completed prefix is worth caching, and
	// short-circuited actions report failure so they can never produce a fresh entry.
	// Never write a manifest under --dry-run - nothing actually happened.
	if((cacheSession != nullptr) && !context->dryRun)
	{
		cacheSession->finalize_and_save();
	}
	context->cacheSession = nullptr;

	REPLAY_PRINT_TIMINGS();

	// ownedTasks goes out of scope here -> all TaskProxy destructors run -> free(inputs) / free(outputs) for each task.
}
