//
//  SchedulerMedusa.m
//
//  Created by Tomasz Kukielka on 9/20/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import "SchedulerMedusa.h"
#import "MedusaTaskProxy.h"

static void FileNodeCFSetConnector(const void *value, void *producerContext)
{
	FileNode *node = (FileNode *)value;
	if(producerContext != NULL)
	{
		node->anyParentHasProducer = 1;
		if(node->producer != NULL) //if parent has a producer and our node has one, we need to connect them
		{
			__unsafe_unretained id<MedusaTask> parentNodeTask = (__bridge __unsafe_unretained id<MedusaTask>)producerContext;
			__unsafe_unretained id<MedusaTask> currNodeTask = (__bridge __unsafe_unretained id<MedusaTask>)node->producer;
			[parentNodeTask linkNextTask:currNodeTask];
		}
	}
	
	if(node->children != NULL)
	{
		if(node->producer != NULL) //and we have a new context to pass to child nodes
			producerContext = node->producer;

		CFSetApplyFunction(node->children, FileNodeCFSetConnector, producerContext);
	}
}

//after the producers are assigned to their nodes we need to walk the whole tree to find
//if there are any implicit producer dependencies
//for example a node creating a directory and a node creating a file in there

void
ConnectImplicitProducers(FileNode *treeRoot)
{
	printf("Connecting implicit producers\n");
    clock_t begin = clock();

	if(treeRoot->children != NULL)
	{
		void *producerContext = treeRoot->producer;
		CFSetApplyFunction(treeRoot->children, FileNodeCFSetConnector, producerContext);
	}

	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
    printf("Finished connecting implicit producers in %f seconds\n", seconds);
}

void
ConnectDynamicInputsForScheduler(NSArray< id<MedusaTask> > *allTasks, //input list of all raw unconnected medusas
								TaskProxy *rootTask)
{
    printf("Connecting all dynamic inputs\n");

    clock_t begin = clock();
    size_t all_input_count = 0;
    size_t static_input_count = 0;


	for(__weak TaskProxy *oneTask in allTasks)
	{
        bool taskHasStaticInputsOnly = true;

		NSUInteger inputCount = oneTask.inputCount;
		FileNode** inputs = oneTask.inputs;
        for(NSUInteger i = 0; i < inputCount; i++)
        {
        	FileNode *node = inputs[i];
         	all_input_count++;
                        
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
            else
            {
            	static_input_count++;
            }

            taskHasStaticInputsOnly = (taskHasStaticInputsOnly && (producerTask == nil));
        }
        
        if(taskHasStaticInputsOnly)
        {//when the task has only static inputs, it gets scheduled for execution first
            [rootTask linkNextTask:oneTask];
        }
    }
    
	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
    printf("Finished connecting all dynamic outputs in %f seconds\n", seconds);
    
    printf("All input count %lu\n", all_input_count);
    printf("Static input count %lu\n", static_input_count);
}

