//
//  RecursiveMedusa.m
//
//  Created by Tomasz Kukielka on 9/13/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import "RecursiveMedusa.h"
#import "MedusaTaskProxy.h"

//first pass
void IndexAllOutputsForRecursiveExecution(NSArray< id<MedusaTask> > *allTasks,
                       	OutputInfo *outputInfoArray, NSUInteger outputArrayCount)
{
    printf("First pass to index all output files\n");
    clock_t begin = clock();
	NSUInteger outputIndex = 0;
	for(__weak id<MedusaTask> oneTask in allTasks)
	{
		NSUInteger outputCount = oneTask.outputCount;
		FileNode** outputs = oneTask.outputs;
        for(NSUInteger i = 0; i < outputCount; i++)
        {
        	FileNode *node = outputs[i];
        	assert(outputIndex < outputArrayCount);
			OutputInfo* outputProducer = &(outputInfoArray[outputIndex]);
			outputProducer->producer = oneTask;
			outputIndex++;
			//no two producers can produce the same output - add runtime validation
			assert(node->producer == NULL);
			// in our in-memory file tree both inputs are outputs are the same nodes
			// so setting it here for the output will allow it to be retrieved later if this node happens
			// to be an input to some other medusa
			
			//For recursive medusa we just stuff pointers to slots in our single allocation array of OutputInfo
			node->producer = outputProducer;
        }
    }

	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;

    printf("Total number of outputs in all medusas %lu\n", outputIndex);
    printf("Finished indexing all outputs in %f seconds\n", seconds);
}


static void FileNodeCFSetConnectConsumers(const void *value, void *producerContext)
{
	FileNode *node = (FileNode *)value;
	if(producerContext != NULL)
	{
		node->anyParentHasProducer = 1;
		if(node->producer != NULL) //if parent has a producer and our node has one, we need to connect them
		{
			OutputInfo *parentProducerInfo = (OutputInfo *)producerContext;
			OutputInfo *currProducerInfo = (OutputInfo *)node->producer;
			if(parentProducerInfo->consumers == nil)
				parentProducerInfo->consumers = [[NSMutableSet alloc] initWithCapacity:0];
			[parentProducerInfo->consumers addObject:currProducerInfo->producer];// add oneself to the list of consumers
		}
	}
	
	if(node->children != NULL)
	{
		if(node->producer != NULL) //and we have a new context to pass to child nodes
			producerContext = node->producer;

		CFSetApplyFunction(node->children, FileNodeCFSetConnectConsumers, producerContext);
	}
}

//after the producers are assigned to their nodes we need to walk the whole tree to find
//if there are any implicit producer dependencies
//for example a node creating a directory and a node creating a file in there

void
ConnectImplicitProducersForRecursiveExecution(FileNode *treeRoot)
{
	printf("Connecting implicit producers\n");
    clock_t begin = clock();

	if(treeRoot->children != NULL)
	{
		void *producerContext = treeRoot->producer;
		CFSetApplyFunction(treeRoot->children, FileNodeCFSetConnectConsumers, producerContext);
	}

	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
    printf("Finished connecting implicit producers in %f seconds\n", seconds);
}


//second pass - connect outputs to inputs, gather info about consumers and producers
//find first medusas without dependencies

NSSet<MedusaTaskProxy *> * //medusas without dynamic dependencies to be executed first - produced here
ConnectDynamicInputsForRecursiveExecution(NSArray<MedusaTaskProxy *> *allTasks) //input list of all raw unconnected medusas
{
    printf("Connecting all dynamic inputs\n");
    
    clock_t begin = clock();
    size_t all_input_count = 0;
    size_t static_input_count = 0;

	NSMutableSet<MedusaTaskProxy *> *staticInputTasks = [[NSMutableSet alloc] initWithCapacity:0];

	for(__weak MedusaTaskProxy *oneTask in allTasks)
	{
        bool are_all_inputs_satisfied = true;

		NSUInteger inputCount = oneTask.inputCount;
		FileNode** inputs = oneTask.inputs;
        for(NSUInteger i = 0; i < inputCount; i++)
        {
        	FileNode *node = inputs[i];
         	all_input_count++;
            
            //find if this medusa's input is known to be produced by another one
            OutputInfo *outputProducer = (OutputInfo *)node->producer;
            if(outputProducer != NULL)
            {
                if(outputProducer->consumers == nil)
	                outputProducer->consumers = [[NSMutableSet alloc] initWithCapacity:0];
                [outputProducer->consumers addObject:oneTask];// add oneself to the list of consumers
            }
            else if(node->anyParentHasProducer)
            {//we know there is a producer up the tree in one of the parent nodes
            	FileNode *parentNode = node->parent;
            	while(parentNode != NULL)
            	{
            		if(parentNode->producer != NULL)
            		{
						outputProducer = (OutputInfo *)parentNode->producer;
						if(outputProducer->consumers == nil)
							outputProducer->consumers = [[NSMutableSet alloc] initWithCapacity:0];
						[outputProducer->consumers addObject:oneTask];// add oneself to the list of consumers
						break;
            		}
            		parentNode = parentNode->parent;
            	}
            }
            else
            {
            	static_input_count++;
            }

            are_all_inputs_satisfied = (are_all_inputs_satisfied && (outputProducer == NULL));
        }
        
        if(are_all_inputs_satisfied)
        {
			[staticInputTasks addObject:oneTask];
        }
    }
    
	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
    printf("Finished connecting all dynamic outputs in %f seconds\n", seconds);
    
    printf("All input count %lu\n", all_input_count);
    printf("Static input count %lu\n", static_input_count);
    printf("Initial count of medusas with static dependencies only: %lu\n", staticInputTasks.count);
    
    return staticInputTasks;
}


// This function executes recursively in much longer time than the corresponding C++ code in medusa3
// For example 1 million medusa test runs this one for 16-18 seconds compared to 7-8 seconds in C++.
// On the first look there is nothing that much expensive going on here and the same operations are perfomred in C++ on STL containers:
// - we have 4 nested container iterators
// - we have no dictionary lookups
// - we populate one medusa array for the next nested iteration
//

void ExecuteMedusaGraphRecursively(NSSet<MedusaTaskProxy *> *taskSet)
{
    NSMutableSet<MedusaTaskProxy *> *nextTaskSet = [[NSMutableSet alloc] initWithCapacity:0];
    for(__weak MedusaTaskProxy *oneTask in taskSet)
	{
		// ****** EXECUTE ******
		
#if ENABLE_DEBUG_DUMP
		[oneTask dumpDescription];
#endif
		[oneTask executeTask];
		
		// consider one_medusa executed here

		NSUInteger outputCount = oneTask.outputCount;
		FileNode** outputs = oneTask.outputs;
        for(NSUInteger i = 0; i < outputCount; i++)
        {
        	FileNode *outputNode = outputs[i];
        	//mark all path specs coming out from this medusa as produced now
            OutputInfo *outputProducer = (OutputInfo *)outputNode->producer;

			// now look ahead at consuming nodes and check if all inputs are satisifed now
			for(__weak MedusaTaskProxy *consumerTask in outputProducer->consumers)
			{
				if(consumerTask.executed) //if the task has already been executed by other path do not schedule it again
					continue;

				bool are_all_inputs_satisfied = true;
				
				NSUInteger inputCount = consumerTask.inputCount;
				FileNode** inputs = consumerTask.inputs;
				for(NSUInteger i = 0; i < inputCount; i++)
				{
					FileNode *input_node = inputs[i];
					OutputInfo * oneProducer = (OutputInfo *)input_node->producer;
					bool is_input_satisfied = (oneProducer == NULL); //is static
					if(oneProducer != NULL)
					{
						//check if the producer for this input has been executed already
						MedusaTaskProxy *recursiveTask = (MedusaTaskProxy *)oneProducer->producer;
						is_input_satisfied = recursiveTask.executed;
					}
					are_all_inputs_satisfied = (are_all_inputs_satisfied && is_input_satisfied);
					if(!are_all_inputs_satisfied)
						break;
				}

				if(are_all_inputs_satisfied)
				{
					[nextTaskSet addObject:consumerTask];
				}
			}
        }
    }

    if(nextTaskSet.count > 0)
    {
        //now recursively go over next medusas and follow the outputs to find the ones with all satisifed inputs
        ExecuteMedusaGraphRecursively(nextTaskSet);
    }
    else
    {
        // std::cout << "No more medusas with all satsfied inputs found. Done\n";
    }
}

#if ENABLE_DEBUG_DUMP

void DumpOneRecursiveTaskLevel(NSSet<MedusaTaskProxy*> *taskSet, int level)
{
    for(__weak MedusaTaskProxy *oneTask in taskSet)
	{
		for(int l=0; l<level; l++) printf("  ");
		printf("MedusaTaskProxy=%p\n", (__bridge void *)oneTask);
		NSUInteger outputCount = oneTask.outputCount;
		FileNode** outputs = oneTask.outputs;
        for(NSUInteger i = 0; i < outputCount; i++)
        {
        	FileNode *outputNode = outputs[i];
			for(int l=0; l<(level+1); l++) printf("  ");
			printf("consumers of output %d: ", (int)i);
        	DumpBranchForNode(outputNode);
			
            OutputInfo *outputProducerInfo = (OutputInfo *)outputNode->producer;
            NSSet< MedusaTaskProxy*> *consumerSet = (NSSet< MedusaTaskProxy*> *)outputProducerInfo->consumers;
			DumpOneRecursiveTaskLevel(consumerSet, level+2);
		}
	}
}


void DumpRecursiveTaskTree(NSSet<MedusaTaskProxy*> *rootTaskSet)
{
	printf("---------------------------\n");
	printf("Dumping recursive task tree:\n");
	DumpOneRecursiveTaskLevel(rootTaskSet, 0);
	printf("---------------------------\n");
}

#endif //ENABLE_DEBUG_DUMP

