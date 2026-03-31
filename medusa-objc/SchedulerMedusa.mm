//
//  SchedulerMedusa.m
//
//  Created by Tomasz Kukielka on 9/20/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import "SchedulerMedusa.h"
#import "TaskProxyGlob.h"
#include "LogStream.h"
#include "GlobOverlap.h"

//#define TRACE 1

typedef struct _FileNodeVisitorContext
{
	__unsafe_unretained id<MedusaTask> parentNodeTask;
	uint8_t parentIsExclusiveInput;
	uint8_t parentHasConsumer;
} FileNodeVisitorContext;

static void FileNodeCFSetConnector(const void *value, void *inParentContext)
{
	FileNode *node = (FileNode *)value;
	FileNodeVisitorContext *parentContext = (FileNodeVisitorContext *)inParentContext;
	if(parentContext->parentNodeTask != NULL)
	{
		node->anyParentHasProducer = 1;
		if(node->producer != NULL) //if parent has a producer and our node has one, we need to connect them
		{
			__unsafe_unretained id<MedusaTask> currNodeTask = (__bridge __unsafe_unretained id<MedusaTask>)node->producer;
			[parentContext->parentNodeTask linkNextTask:currNodeTask];
		}
	}
	
	if(parentContext->parentIsExclusiveInput != 0)
	{
		// every consumption or additional production under subdir of an exclusive node is a violation
		// let's distinguish 2 cases and give appropriate failure reason
		assert(parentContext->parentHasConsumer != 0); //exclusive input is coming with one consumer already

		if(node->hasConsumer != 0)
		{
			// if a child node also has a consumer, this is an exclusive input violation we did not detect earlier
			char posixPath[2048];
			posixPath[0] = 0;
			GetPathForNode(node, posixPath, sizeof(posixPath));
			fprintf(gLogErr, "error: invalid playlist for concurrent execution.\n"
				"The input path: \"%s\"\n"
				"is used by one action but its parent path is specified as an exclusive input for other action.\n"
				"See \"replay --help\" for more information about exclusive inputs.\n", posixPath);
			safe_exit(EXIT_FAILURE);
		}
		else if((node->producer != NULL) && (node->producer != (__bridge void *)parentContext->parentNodeTask))
		{
			// if not a consumed node then it is prodcued under exclusive path subdir
			// we only allow this case if the producer of the parent and this one are the same
			// otherwise it effectively means that one action deletes the dir and another action wants to produce something under it
			char posixPath[2048];
			posixPath[0] = 0;
			GetPathForNode(node, posixPath, sizeof(posixPath));
			fprintf(gLogErr, "error: invalid playlist for concurrent execution.\n"
				"The input path: \"%s\"\n"
				"is produced by one action (declared as an output) but it has a parent directory\n"
				"specified as an exclusive input for another action (like delete of move)\n"
				"See \"replay --help\" for more information about exclusive inputs.\n", posixPath);
			safe_exit(EXIT_FAILURE);
		}
		assert((node->producer == NULL) || (node->producer == (__bridge void *)parentContext->parentNodeTask));
	}

	if(node->children != NULL)
	{
		// cannot use parent storage so the mutated context does not propagate from sibling to sibling
		// allocate our own context storage here
		FileNodeVisitorContext visitorContext =
		{
			//override the parent values if our node has changed something and has new values to pass to child nodes
			(node->producer != NULL)      ? (__bridge __unsafe_unretained id<MedusaTask>)node->producer : parentContext->parentNodeTask,
			(node->isExclusiveInput != 0) ? (uint8_t)1 : parentContext->parentIsExclusiveInput,
			(node->hasConsumer != 0)      ? (uint8_t)1 : parentContext->parentHasConsumer
		};

		CFSetApplyFunction(node->children, FileNodeCFSetConnector, &visitorContext);
	}
}

//after the producers are assigned to their nodes we need to walk the whole tree to find
//if there are any implicit producer dependencies
//for example a node creating a directory and a node creating a file in there

void
ConnectImplicitProducers(FileNode *treeRoot)
{
#if TRACE
	printf("Connecting implicit producers\n");
    clock_t begin = clock();
#endif //TRACE

	if(treeRoot->children != NULL)
	{
		FileNodeVisitorContext visitorContext =
		{
			(__bridge __unsafe_unretained id<MedusaTask>)treeRoot->producer,
			(uint8_t)(treeRoot->isExclusiveInput != 0),
			(uint8_t)(treeRoot->hasConsumer != 0)
		};
		CFSetApplyFunction(treeRoot->children, FileNodeCFSetConnector, &visitorContext);
	}

#if TRACE
	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
    printf("Finished connecting implicit producers in %f seconds\n", seconds);
#endif //TRACE
}

void
ConnectDynamicInputsForScheduler(NSArray< id<MedusaTask> > *allTasks, //input list of all raw unconnected medusas
								TaskProxy *rootTask)
{
#if TRACE
    printf("Connecting all dynamic inputs\n");

    clock_t begin = clock();

    size_t all_input_count = 0;
    size_t static_input_count = 0;
#endif //TRACE

	for(__unsafe_unretained TaskProxy *oneTask in allTasks)
	{
        bool taskHasStaticInputsOnly = true;

#if ENABLE_DEBUG_DUMP
		[oneTask dumpDescription];
#endif

		NSUInteger inputCount = oneTask.inputCount;
		FileNode** inputs = oneTask.inputs;
        for(NSUInteger i = 0; i < inputCount; i++)
        {
        	FileNode *node = inputs[i];
#if TRACE
         	all_input_count++;
#endif
            //find if this medusa's input is known to be produced by another one
			__unsafe_unretained id<MedusaTask> producerTask = (__bridge __unsafe_unretained id<MedusaTask>)node->producer;
            if(producerTask != nil)
            {
                [producerTask linkNextTask:oneTask];
            }
            else if(node->anyParentHasProducer)
            {//we know there is a producer up the tree in one of the parent nodes
            	FileNode *parentNode = node->parent;
            	while(parentNode != NULL)
            	{
            		if(parentNode->producer != NULL)
            		{
            			producerTask = (__bridge __unsafe_unretained id<MedusaTask>)parentNode->producer;
						[producerTask linkNextTask:oneTask];
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

            taskHasStaticInputsOnly = (taskHasStaticInputsOnly && (producerTask == nil));
        }
        
        if(taskHasStaticInputsOnly)
        {//when the task has only static inputs, it gets scheduled for execution first
            [rootTask linkNextTask:oneTask];
        }
    }
    
#if TRACE
	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
    printf("Finished connecting all dynamic outputs in %f seconds\n", seconds);
    
    printf("All input count %lu\n", all_input_count);
    printf("Static input count %lu\n", static_input_count);
#endif //TRACE
}

// ============================================================================
// Glob-based dependency connection
//
// Handles three cases for dependencies that can't be resolved via the FileTree:
//   Case 1: glob output to glob input — use NFA product construction to detect overlap
//   Case 2: concrete output to glob input — use glob_match to check if concrete path matches
//   Case 3: glob output to concrete input — use glob_match to check if concrete path matches
//
// For each overlapping pair, the producer task is linked to the consumer task
// via [producerTask linkNextTask:consumerTask].
// ============================================================================

// Helper: check if a concrete path matches a glob pattern using glob-cpp
static bool concrete_matches_glob(const std::string& concretePath, const std::string& pattern) {
	glob::glob g(pattern);
	return glob_match(concretePath, g);
}

void
ConnectGlobDependencies(NSArray<TaskProxy*> *allTasks)
{
#if TRACE
	printf("Connecting glob dependencies\n");
	clock_t begin = clock();
#endif

	for(__unsafe_unretained TaskProxy *consumerTask in allTasks)
	{
		const auto& globInputs = [consumerTask globInputs];
		const auto& globExclusiveInputs = [consumerTask globExclusiveInputs];

		if(globInputs.empty() && globExclusiveInputs.empty())
			continue;

		// Check both regular and exclusive glob inputs against all producers.
		// The exclusive vs regular distinction doesn't matter for producer→consumer linking.
		const std::vector<std::string>* inputSets[] = { &globInputs, &globExclusiveInputs };
		for(const auto* inputSet : inputSets)
		{
			for(const auto& inputPattern : *inputSet)
			{
				for(__unsafe_unretained TaskProxy *producerTask in allTasks)
				{
					if(producerTask == consumerTask)
						continue;

					// Case 1: check producer's glob outputs against this glob input
					const auto& producerGlobOutputs = [producerTask globOutputs];
					for(const auto& outputPattern : producerGlobOutputs)
					{
						if(globoverlap::patterns_overlap(outputPattern, inputPattern))
						{
							[producerTask linkNextTask:consumerTask];
							goto next_producer; // one link is enough per producer-consumer pair
						}
					}

					// Case 2: check producer's concrete outputs against this glob input
					{
						NSUInteger outputCount = producerTask.outputCount;
						FileNode** outputs = producerTask.outputs;
						for(NSUInteger i = 0; i < outputCount; i++)
						{
							char path[2048];
							GetPathForNode(outputs[i], path, sizeof(path));
							if(concrete_matches_glob(path, inputPattern))
							{
								[producerTask linkNextTask:consumerTask];
								goto next_producer;
							}
						}
					}

					next_producer:;
				}
			}
		}
	}

	// Also handle Case 3 in reverse: tasks with glob outputs need to be checked
	// against tasks with concrete inputs (those were inserted into FileTree,
	// but a glob output producer won't appear as a node producer there)
	for(__unsafe_unretained TaskProxy *producerTask in allTasks)
	{
		const auto& globOutputs = [producerTask globOutputs];
		if(globOutputs.empty())
			continue;

		for(const auto& outputPattern : globOutputs)
		{
			for(__unsafe_unretained TaskProxy *consumerTask in allTasks)
			{
				if(consumerTask == producerTask)
					continue;

				// Check if any concrete input of the consumer matches the glob output
				NSUInteger inputCount = consumerTask.inputCount;
				FileNode** inputs = consumerTask.inputs;
				for(NSUInteger i = 0; i < inputCount; i++)
				{
					char path[2048];
					GetPathForNode(inputs[i], path, sizeof(path));
					if(concrete_matches_glob(path, outputPattern))
					{
						[producerTask linkNextTask:consumerTask];
						goto next_consumer;
					}
				}

				next_consumer:;
			}
		}
	}

#if TRACE
	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
	printf("Finished connecting glob dependencies in %f seconds\n", seconds);
#endif
}

