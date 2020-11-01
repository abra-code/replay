//
//  SchedulerMedusa.m
//
//  Created by Tomasz Kukielka on 9/20/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import "SchedulerMedusa.h"
#import "MedusaTaskProxy.h"

//first pass
void IndexAllOutputsForScheduler(NSArray< id<MedusaTask> > *all_medusas,
                       	__unsafe_unretained id<MedusaTask> *outputInfoArray, NSUInteger outputArrayCount)
{
    printf("First pass to index all output files\n");
    clock_t begin = clock();
	NSUInteger outputIndex = 0;
	for(__weak id<MedusaTask> one_medusa in all_medusas)
	{
		NSUInteger outputCount = one_medusa.outputCount;
		FileNode** outputs = one_medusa.outputs;
        for(NSUInteger i = 0; i < outputCount; i++)
        {
        	FileNode *node = outputs[i];
        	assert(outputIndex < outputArrayCount);
			outputInfoArray[outputIndex] = one_medusa;
			outputIndex++; //intentionally +1 so index 0 is not a built product path
			
			//no two producers can produce the same output - add runtime validation
			assert(node->producerIndex == 0);
			// in our in-memory file tree both inputs are outputs are the same nodes
			// so setting it here for the output will allow it to be retrieved later if this node happens
			// to be an input to some other medusa
			node->producerIndex = outputIndex;
        }
    }

	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;

    printf("Total number of outputs in all medusas %lu\n", outputIndex);
    printf("Finished indexing all outputs in %f seconds\n", seconds);
}

void
ConnectDynamicInputsForScheduler(NSArray< id<MedusaTask> > *all_medusas, //input list of all raw unconnected medusas
						TaskProxy *rootTask,
						__unsafe_unretained id<MedusaTask> *outputInfoArray, NSUInteger outputArrayCount) //the list of all output specs
{
    printf("Connecting all dynamic inputs\n");
    
    clock_t begin = clock();
    size_t all_input_count = 0;
    size_t static_input_count = 0;

	for(__weak TaskProxy *one_medusa in all_medusas)
	{
        bool are_all_inputs_satisfied = true;

		NSUInteger inputCount = one_medusa.inputCount;
		FileNode** inputs = one_medusa.inputs;
        for(NSUInteger i = 0; i < inputCount; i++)
        {
        	FileNode *node = inputs[i];
         	all_input_count++;
            
            //find if this medusa's input is known to be produced by another one
			uint64_t producer_index = node->producerIndex;
            if(producer_index != 0) //0 is a reserved index for static inputs
            {
                assert((producer_index-1) < outputArrayCount);
                id<MedusaTask> outputProducer = outputInfoArray[producer_index-1];
                [outputProducer linkNextTask:one_medusa];
            }
            else
            {
            	static_input_count++;
            }

            are_all_inputs_satisfied = (are_all_inputs_satisfied && (producer_index == 0));
        }
        
        if(are_all_inputs_satisfied)
        {
            [rootTask linkNextTask:one_medusa];
        }
    }
    
	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
    printf("Finished connecting all dynamic outputs in %f seconds\n", seconds);
    
    printf("All input count %lu\n", all_input_count);
    printf("Static input count %lu\n", static_input_count);
}

