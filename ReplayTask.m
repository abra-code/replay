#import "ReplayTask.h"
#import "TaskProxy.h"
#import "SchedulerMedusa.h"
#import "TaskScheduler.h"


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
	if(context->stopOnError && (context->lastError.error != nil))
		return nil;

	__block NSMutableArray<TaskProxy *> *tasksFromStep = [NSMutableArray arrayWithCapacity:0];

	HandleActionStep(replayStep, context,
		^( __nullable dispatch_block_t action,
			NSArray<NSString*> * __nullable inputs,
			NSArray<NSString*> * __nullable exclusiveInputs,
			NSArray<NSString*> * __nullable outputs)
		{
			if(action == nil)
				return;

			TaskProxy *oneTask = [[TaskProxy alloc] initWithTask:action];
			oneTask.stepDescription = replayStep;
			[tasksFromStep addObject:oneTask];

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
				inputList = (FileNode**)malloc(sizeof(FileNode*) * totalInputCount);
				oneTask.inputCount = totalInputCount;
				oneTask.inputs = inputList;
			}
			
			NSUInteger inputIndex = 0;
			if(inputs != nil)
			{
				for(NSString *oneInput in inputs)
				{
					inputList[inputIndex] = FileNodeFromPath(context->fileTreeRoot, oneInput, nil, false);
					inputIndex++;
				}
			}
			
			if(exclusiveInputs != nil)
			{
				for(NSString *oneInput in exclusiveInputs)
				{
					inputList[inputIndex] = FileNodeFromPath(context->fileTreeRoot, oneInput, nil, true);
					inputIndex++;
				}
			}
			assert(inputIndex == totalInputCount);

			if(outputs != nil)
			{
				NSUInteger outputCount = outputs.count;
				if(outputCount > 0)
				{
					FileNode** outputList = (FileNode**)malloc(sizeof(FileNode*) * outputCount);
					NSUInteger i = 0;
					for(NSString *oneOutput in outputs)
					{
						outputList[i] = FileNodeFromPath(context->fileTreeRoot, oneOutput, oneTask, false);
						i++;
					}
					oneTask.outputCount = outputCount;
					oneTask.outputs = outputList;
				}
			}
		});

	return tasksFromStep;
}


static inline void
ExecuteTasksWithScheduler(NSArray<TaskProxy*> *allTasks, ReplayContext *context, NSUInteger inputCount, NSUInteger outputCount)
{
	ConnectImplicitProducers(context->fileTreeRoot);

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
