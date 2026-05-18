#include "SchedulerMedusa.h"
#include "LogStream.h"
#include "GlobOverlap.h"
#include "ReplaySignpost.h"
#include <cassert>
#include <cstdlib>
#include <ctime>

//#define TRACE 1

struct FileNodeVisitorContext
{
	TaskProxy* parentNodeTask;
	uint8_t parentIsExclusiveInput;
	uint8_t parentHasConsumer;
};

static void FileNodeCFSetConnector(FileNode* node, FileNodeVisitorContext* parentContext)
{
	if(parentContext->parentNodeTask != nullptr)
	{
		node->anyParentHasProducer = 1;
		if(node->producer != nullptr)
		{// parent has a producer and this node has one — connect them
			TaskProxy* currNodeTask = static_cast<TaskProxy*>(node->producer);
			parentContext->parentNodeTask->linkNextTask(currNodeTask);
		}
	}

	if(parentContext->parentIsExclusiveInput != 0)
	{
		// Every consumption or production under a subdir of an exclusive node is a violation.
		assert(parentContext->parentHasConsumer != 0);

		if(node->hasConsumer != 0)
		{
			char posixPath[2048];
			posixPath[0] = 0;
			GetPathForNode(node, posixPath, sizeof(posixPath));
			LogError("error: invalid playlist for concurrent execution.\n"
				"The input path: \"%s\"\n"
				"is used by one action but its parent path is specified as an exclusive input for other action.\n"
				"See \"replay --help\" for more information about exclusive inputs.\n", posixPath);
			safe_exit(EXIT_FAILURE);
		}
		else if(node->producer != nullptr && node->producer != static_cast<void*>(parentContext->parentNodeTask))
		{
			char posixPath[2048];
			posixPath[0] = 0;
			GetPathForNode(node, posixPath, sizeof(posixPath));
			LogError("error: invalid playlist for concurrent execution.\n"
				"The input path: \"%s\"\n"
				"is produced by one action (declared as an output) but it has a parent directory\n"
				"specified as an exclusive input for another action (like delete or move)\n"
				"See \"replay --help\" for more information about exclusive inputs.\n", posixPath);
			safe_exit(EXIT_FAILURE);
		}
		assert(node->producer == nullptr || node->producer == static_cast<void*>(parentContext->parentNodeTask));
	}

	if(node->children != nullptr)
	{
		// Use a local context so sibling mutations don't bleed across siblings.
		FileNodeVisitorContext visitorContext =
		{
			(node->producer != nullptr) ? static_cast<TaskProxy*>(node->producer) : parentContext->parentNodeTask,
			(node->isExclusiveInput != 0) ? (uint8_t)1 : parentContext->parentIsExclusiveInput,
			(node->hasConsumer != 0)      ? (uint8_t)1 : parentContext->parentHasConsumer
		};

		for(FileNode* child : *node->children)
			FileNodeCFSetConnector(child, &visitorContext);
	}
}

void
ConnectImplicitProducers(FileNode* treeRoot)
{
#if TRACE
	printf("Connecting implicit producers\n");
	clock_t begin = clock();
#endif

	REPLAY_SIGNPOST_BEGIN("ConnectImplicitProducers");

	if(treeRoot->children != nullptr)
	{
		FileNodeVisitorContext visitorContext =
		{
			static_cast<TaskProxy*>(treeRoot->producer),
			(uint8_t)(treeRoot->isExclusiveInput != 0),
			(uint8_t)(treeRoot->hasConsumer != 0)
		};
		for(FileNode* child : *treeRoot->children)
			FileNodeCFSetConnector(child, &visitorContext);
	}

	REPLAY_SIGNPOST_END("ConnectImplicitProducers");

#if TRACE
	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
	printf("Finished connecting implicit producers in %f seconds\n", seconds);
#endif
}

void
ConnectDynamicInputsForScheduler(const std::vector<TaskProxy*>& allTasks, TaskProxy* rootTask)
{
#if TRACE
	printf("Connecting all dynamic inputs\n");
	clock_t begin = clock();
	size_t all_input_count = 0;
	size_t static_input_count = 0;
#endif

	REPLAY_SIGNPOST_BEGIN("ConnectDynamicInputs", "task_count=%zu", allTasks.size());

	for(TaskProxy* oneTask : allTasks)
	{
		bool taskHasStaticInputsOnly = true;

#if ENABLE_DEBUG_DUMP
		oneTask->dumpDescription();
#endif

		FileNode** inputs = oneTask->inputs;
		for(size_t i = 0; i < oneTask->inputCount; i++)
		{
			FileNode* node = inputs[i];
#if TRACE
			all_input_count++;
#endif
			TaskProxy* producerTask = static_cast<TaskProxy*>(node->producer);
			if(producerTask != nullptr)
			{
				producerTask->linkNextTask(oneTask);
			}
			else if(node->anyParentHasProducer)
			{
				FileNode* parentNode = node->parent;
				while(parentNode != nullptr)
				{
					if(parentNode->producer != nullptr)
					{
						producerTask = static_cast<TaskProxy*>(parentNode->producer);
						producerTask->linkNextTask(oneTask);
						break;
					}
					parentNode = parentNode->parent;
				}
			}
#if TRACE
			else
			{
				static_input_count++;
			}
#endif
			taskHasStaticInputsOnly = (taskHasStaticInputsOnly && (producerTask == nullptr));
		}

		if(taskHasStaticInputsOnly)
			rootTask->linkNextTask(oneTask);
	}

	REPLAY_SIGNPOST_END("ConnectDynamicInputs");

#if TRACE
	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
	printf("Finished connecting all dynamic outputs in %f seconds\n", seconds);
	printf("All input count %zu\n", all_input_count);
	printf("Static input count %zu\n", static_input_count);
#endif
}

// Helper: check if a concrete lowercased path matches a pre-compiled glob.
// Automata::Exec() calls ResetStates() after every match so the glob is
// safe to reuse across multiple calls within a single thread.
static inline bool concrete_matches_glob(const std::string& concretePath, glob::glob& g)
{
	return glob_match(concretePath, g);
}

void
ConnectGlobDependencies(const std::vector<TaskProxy*>& allTasks)
{
#if TRACE
	printf("Connecting glob dependencies\n");
	clock_t begin = clock();
#endif

	REPLAY_SIGNPOST_BEGIN("ConnectGlobDependencies", "task_count=%zu", allTasks.size());

	// Case 1 & 2: glob inputs against glob/concrete outputs of all producers.
	for(TaskProxy* consumerTask : allTasks)
	{
		const auto& globInputs = consumerTask->globInputs;
		const auto& globExclusiveInputs = consumerTask->globExclusiveInputs;

		if(globInputs.empty() && globExclusiveInputs.empty())
			continue;

		const std::vector<std::string>* inputSets[] = { &globInputs, &globExclusiveInputs };
		for(const auto* inputSet : inputSets)
		{
			for(const auto& inputPattern : *inputSet)
			{
				glob::glob inputG(inputPattern);
				for(TaskProxy* producerTask : allTasks)
				{
					if(producerTask == consumerTask)
						continue;

					// Case 1: producer's glob outputs vs this glob input
					for(const auto& outputPattern : producerTask->globOutputs)
					{
						if(globoverlap::patterns_overlap(outputPattern, inputPattern))
						{
							producerTask->linkNextTask(consumerTask);
							goto next_producer;
						}
					}

					// Case 2: producer's concrete outputs vs this glob input
					{
						FileNode** outputs = producerTask->outputs;
						for(size_t i = 0; i < producerTask->outputCount; i++)
						{
							char path[2048];
							GetPathForNode(outputs[i], path, sizeof(path));
							if(concrete_matches_glob(path, inputG))
							{
								producerTask->linkNextTask(consumerTask);
								goto next_producer;
							}
						}
					}

					next_producer:;
				}
			}
		}
	}

	// Case 3: glob outputs against concrete inputs (reverse direction).
	for(TaskProxy* producerTask : allTasks)
	{
		const auto& globOutputs = producerTask->globOutputs;
		if(globOutputs.empty())
			continue;

		for(const auto& outputPattern : globOutputs)
		{
			glob::glob outputG(outputPattern);
			for(TaskProxy* consumerTask : allTasks)
			{
				if(consumerTask == producerTask)
					continue;

				FileNode** inputs = consumerTask->inputs;
				for(size_t i = 0; i < consumerTask->inputCount; i++)
				{
					char path[2048];
					GetPathForNode(inputs[i], path, sizeof(path));
					if(concrete_matches_glob(path, outputG))
					{
						producerTask->linkNextTask(consumerTask);
						goto next_consumer;
					}
				}

				next_consumer:;
			}
		}
	}

	// -------------------------------------------------------------------------
	// Mutating input dependency passes (A, B, C).
	//
	// M = a mutating pattern on task T (glob or concrete, always lowercased).
	//   Pass A: any producer whose outputs overlap M must run before T.
	//   Pass B: a consumer whose inputs overlap M runs before T (earlier playlist)
	//           or after T (later playlist) to respect user intent.
	//   Pass C: two mutating tasks with overlapping M are chained by playlist
	//           order; Pass A/B are skipped for that pair.
	// -------------------------------------------------------------------------

	auto lowercase_copy = [](const std::string& s) {
		std::string r = s;
		for(auto& c : r) c = (char)tolower((unsigned char)c);
		return r;
	};

	size_t taskCount = allTasks.size();
	for(size_t mutatorIndex = 0; mutatorIndex < taskCount; mutatorIndex++)
	{
		TaskProxy* mutatingTask = allTasks[mutatorIndex];

		std::vector<std::string> mutatingPatterns;
		{
			const auto& glob = mutatingTask->globMutatingInputs;
			const auto& concrete = mutatingTask->concreteMutatingPaths;
			mutatingPatterns.reserve(glob.size() + concrete.size());
			for(const auto& p : glob)     mutatingPatterns.push_back(lowercase_copy(p));
			for(const auto& p : concrete) mutatingPatterns.push_back(p);
		}
		if(mutatingPatterns.empty())
			continue;

		for(const auto& mutPat : mutatingPatterns)
		{
			glob::glob mutG(mutPat);
			for(size_t otherIndex = 0; otherIndex < taskCount; otherIndex++)
			{
				if(otherIndex == mutatorIndex)
					continue;

				TaskProxy* otherTask = allTasks[otherIndex];

				// Pass C: both are mutators — chain by playlist order if patterns overlap.
				bool otherIsMutator = (!otherTask->globMutatingInputs.empty()
				                    || !otherTask->concreteMutatingPaths.empty());
				if(otherIsMutator)
				{
					bool overlapping = false;
					for(const auto& rawOtherPat : otherTask->globMutatingInputs)
					{
						if(globoverlap::patterns_overlap(lowercase_copy(rawOtherPat), mutPat))
						{
							overlapping = true;
							break;
						}
					}
					if(!overlapping)
					{
						for(const auto& otherPat : otherTask->concreteMutatingPaths)
						{
							if(globoverlap::patterns_overlap(otherPat, mutPat))
							{
								overlapping = true;
								break;
							}
						}
					}
					if(overlapping)
					{
						if(otherIndex < mutatorIndex)
							otherTask->linkNextTask(mutatingTask);
						// otherIndex > mutatorIndex: the outer loop will handle it
						continue; // skip Pass A/B for this overlapping mutator pair
					}
				}

				// Pass A: otherTask produces files matching mutPat -> run before mutatingTask.
				bool linked = false;
				for(const auto& rawOutPat : otherTask->globOutputs)
				{
					if(globoverlap::patterns_overlap(lowercase_copy(rawOutPat), mutPat))
					{
						otherTask->linkNextTask(mutatingTask);
						linked = true;
						break;
					}
				}
				if(!linked)
				{
					FileNode** outputs = otherTask->outputs;
					for(size_t i = 0; i < otherTask->outputCount; i++)
					{
						char path[2048];
						GetPathForNode(outputs[i], path, sizeof(path));
						if(concrete_matches_glob(path, mutG))
						{
							otherTask->linkNextTask(mutatingTask);
							break;
						}
					}
				}

				// Pass B: otherTask consumes files matching mutPat; direction by playlist order.
				bool consumed = false;
				for(const auto& rawInPat : otherTask->globInputs)
				{
					if(globoverlap::patterns_overlap(mutPat, lowercase_copy(rawInPat)))
					{
						consumed = true;
						break;
					}
				}
				if(!consumed)
				{
					for(const auto& rawInPat : otherTask->globExclusiveInputs)
					{
						if(globoverlap::patterns_overlap(mutPat, lowercase_copy(rawInPat)))
						{
							consumed = true;
							break;
						}
					}
				}
				if(!consumed)
				{
					FileNode** inputs = otherTask->inputs;
					for(size_t i = 0; i < otherTask->inputCount; i++)
					{
						char path[2048];
						GetPathForNode(inputs[i], path, sizeof(path));
						if(concrete_matches_glob(path, mutG))
						{
							consumed = true;
							break;
						}
					}
				}
				if(consumed)
				{
					if(otherIndex > mutatorIndex)
						mutatingTask->linkNextTask(otherTask); // post-mutation reader
					else
						otherTask->linkNextTask(mutatingTask); // pre-mutation reader
				}
			}
		}
	}

	REPLAY_SIGNPOST_END("ConnectGlobDependencies");

#if TRACE
	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
	printf("Finished connecting glob dependencies in %f seconds\n", seconds);
#endif
}
