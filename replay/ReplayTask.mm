#import "ReplayTask.h"
#import "TaskProxyGlob.h"
#import "SchedulerMedusa.h"
#import "TaskScheduler.h"
#include "GlobOverlap.h"


static inline FileNode * FileNodeFromPath(FileNode *fileTreeRoot, NSString *path, TaskProxy* producer, bool isExclusiveInput)
{
	NSString *lowercasePath = [path lowercaseString];
	const char *posixPath = [lowercasePath fileSystemRepresentation];
	FileNode *outNode = FindOrInsertFileNodeForPath(fileTreeRoot, posixPath);
	//Input nodes don't have a producer.
	//important not to reset to NULL to not override what might have been set already
	if(producer != nil)
	{
		if(outNode->producer != NULL)
		{
			posixPath = [path fileSystemRepresentation];
			fprintf(gLogErr, "error: invalid playlist for concurrent execution.\n"
				"The output path: \"%s\"\n"
				"is specified as a product of two or more actions.\n"
				"See \"replay --help\" for more information about concurrent execution constraints.\n", posixPath);
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
			posixPath = [path fileSystemRepresentation];
			fprintf(gLogErr, "error: invalid playlist for concurrent execution.\n"
				"The path: \"%s\"\n"
				"is specified as an exclusive input for one action (like move or delete) but\n"
				"there is more than one action consuming it.\n"
				"See \"replay --help\" for more information about exclusive inputs.\n", posixPath);
			safe_exit(EXIT_FAILURE);
		}

		outNode->hasConsumer = 1;
	}

	return outNode;
}

NSArray<TaskProxy *> *
TasksFromStep(NSDictionary *replayStep, ReplayContext *context)
{
	if(context->stopOnError && (context->lastError.hasError()))
		return nil;

	__block NSMutableArray<TaskProxy *> *tasksFromStep = [NSMutableArray arrayWithCapacity:0];

	HandleActionStep(replayStep, context,
		^( __nullable dispatch_block_t action,
			NSArray<NSString*> * __nullable inputs,
			NSArray<NSString*> * __nullable mutatingInputs,
			NSArray<NSString*> * __nullable exclusiveInputs,
			NSArray<NSString*> * __nullable outputs)
		{
			if(action == nil)
				return;

			TaskProxy *oneTask = [[TaskProxy alloc] initWithTask:action];
			oneTask.stepDescription = replayStep;
			[tasksFromStep addObject:oneTask];

			// Classify each input/output path: glob patterns go to TaskProxy's glob properties
			// for later overlap-based dependency analysis; concrete paths go into the FileTree
			// as before for exact node-based dependency tracking.

			std::vector<std::string> globInputList;
			std::vector<std::string> globExclusiveInputList;
			std::vector<std::string> globMutatingInputList;
			std::vector<std::string> concreteMutatingPathList;

			NSUInteger regularInputCount = 0;
			if(inputs != nil)
				regularInputCount = inputs.count;

			NSUInteger exclusiveInputCount = 0;
			if(exclusiveInputs != nil)
				exclusiveInputCount = exclusiveInputs.count;

			NSUInteger totalInputCount = regularInputCount + exclusiveInputCount;
			FileNode** inputList = NULL;
			if(totalInputCount > 0)
			{
				// Allocate for worst case (all concrete); actual count may be smaller
				inputList = (FileNode**)malloc(sizeof(FileNode*) * totalInputCount);
			}

			NSUInteger concreteInputIndex = 0;
			if(inputs != nil)
			{
				for(NSString *oneInput in inputs)
				{
					std::string path([oneInput UTF8String]);
					if(globoverlap::is_glob_pattern(path))
					{
						globInputList.push_back(std::move(path));
					}
					else
					{
						inputList[concreteInputIndex] = FileNodeFromPath(context->fileTreeRoot, oneInput, nil, false);
						concreteInputIndex++;
					}
				}
			}

			if(exclusiveInputs != nil)
			{
				for(NSString *oneInput in exclusiveInputs)
				{
					std::string path([oneInput UTF8String]);
					if(globoverlap::is_glob_pattern(path))
					{
						globExclusiveInputList.push_back(std::move(path));
					}
					else
					{
						inputList[concreteInputIndex] = FileNodeFromPath(context->fileTreeRoot, oneInput, nil, true);
						concreteInputIndex++;
					}
				}
			}

			if(mutatingInputs != nil)
			{
				for(NSString *oneInput in mutatingInputs)
				{
					std::string path([oneInput UTF8String]);
					if(globoverlap::is_glob_pattern(path))
					{
						globMutatingInputList.push_back(std::move(path));
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
					NSString *lowercasePath = [oneInput lowercaseString];
					const char *posixPath = [lowercasePath fileSystemRepresentation];
					FileNode *node = FindOrInsertFileNodeForPath(context->fileTreeRoot, posixPath);

					if(node->isExclusiveInput != 0)
					{
						posixPath = [oneInput fileSystemRepresentation];
						fprintf(gLogErr, "error: invalid playlist for concurrent execution.\n"
							"The path: \"%s\"\n"
							"is specified as a mutating input (e.g. edit) but another action has marked it\n"
							"as an exclusive input (delete or move). These cannot apply to the same path.\n"
							"See \"replay --help\" for more information.\n", posixPath);
						safe_exit(EXIT_FAILURE);
					}

					// Conditional FileTree producer-replacement: only when no prior
					// consumer has registered this path. Without prior consumers the
					// FileTree edge mutator → next-consumer is the right direction;
					// with prior consumers, that edge would conflict with Pass B's
					// pre-mutation reader edge (consumer → mutator), creating a
					// cycle. Skipping the replacement in that case lets Pass B
					// handle ordering on both sides per playlist position.
					if(node->hasConsumer == 0)
					{
						node->producer = (__bridge void *)oneTask;
					}

					// Lowercase posix path so concrete-vs-concrete and concrete-vs-glob
					// comparisons in ConnectGlobDependencies match GetPathForNode output.
					concreteMutatingPathList.push_back(std::string([lowercasePath UTF8String]));
				}
			}

			if(concreteInputIndex > 0)
			{
				oneTask.inputCount = concreteInputIndex;
				oneTask.inputs = inputList;
			}
			else if(inputList != NULL)
			{
				free(inputList);
			}

			[oneTask setGlobInputs:std::move(globInputList)];
			[oneTask setGlobExclusiveInputs:std::move(globExclusiveInputList)];
			[oneTask setGlobMutatingInputs:std::move(globMutatingInputList)];
			[oneTask setConcreteMutatingPaths:std::move(concreteMutatingPathList)];

			std::vector<std::string> globOutputList;

			if(outputs != nil)
			{
				NSUInteger outputCount = outputs.count;
				if(outputCount > 0)
				{
					FileNode** outputList = (FileNode**)malloc(sizeof(FileNode*) * outputCount);
					NSUInteger concreteOutputIndex = 0;
					for(NSString *oneOutput in outputs)
					{
						std::string path([oneOutput UTF8String]);
						if(globoverlap::is_glob_pattern(path))
						{
							globOutputList.push_back(std::move(path));
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
						oneTask.outputs = outputList;
					}
					else
					{
						free(outputList);
					}
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

	[scheduler startExecutionAndWait];
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
				fprintf(gLogErr, "error: not all tasks have been executed.\n"
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
DispatchTasksConcurrentlyWithDependencyAnalysis(NSArray<NSDictionary*> *playlist, ReplayContext *context)
{
	assert(context->concurrent);
	DeleteFileTree(context->fileTreeRoot);
	context->fileTreeRoot = CreateFileTreeRoot();

    NSMutableArray<TaskProxy*> *taskList = [[NSMutableArray alloc] initWithCapacity:0];
	NSUInteger totalInputCount = 0;
	NSUInteger totalOutputCount = 0;

	Class dictionaryClass = [NSDictionary class];

	for(id oneStep in playlist)
	{
		if([oneStep isKindOfClass:dictionaryClass])
		{
			NSArray<TaskProxy *> *stepTasks = TasksFromStep((NSDictionary *)oneStep, context);
			for(TaskProxy *oneTask in stepTasks)
			{
				[taskList addObject:oneTask];
				totalInputCount += oneTask.inputCount;
				totalOutputCount += oneTask.outputCount;
			}
		}
		else
		{
			fprintf(gLogErr, "error: invalid non-dictionary step in the playlist\n");
		}
	}
	
	// at that point the whole input and output paths tree is already constructed
	// with all explicit producers referred in their respective nodes
	
	ExecuteTasksWithScheduler(taskList, context, totalInputCount, totalOutputCount);

	// Post-execution verification
	// in case of circular dependencies some tasks were not scheduled for execution
	// because their dependencies have not been satisifed (the dependency counter never dropped to 0)
	VerifyAllTasksExecuted(taskList);
}
