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
						CFMutableDictionaryRef output_paths_to_producer_indexes,
                       	__unsafe_unretained id<MedusaTask> *outputInfoArray, NSUInteger outputArrayCount)
{
    printf("First pass to index all output files\n");
    clock_t begin = clock();
	NSUInteger outputIndex = 0;
	for( id<MedusaTask> one_medusa in all_medusas)
	{
        for(PathSpec *one_output in one_medusa.outputs)
        {
        	assert(outputIndex < outputArrayCount);
			outputInfoArray[outputIndex] = one_medusa;
			outputIndex++; //intentionally +1 so index 0 is not a built product path
			one_output.producerIndex = outputIndex;
			//no two producers can produce the same output - validation would be required
			CFDictionaryAddValue(output_paths_to_producer_indexes, (const void *)one_output.path, (const void *)outputIndex);
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
						CFDictionaryRef output_paths_to_producer_indexes, //the helper map produced in first pass
						__unsafe_unretained id<MedusaTask> *outputInfoArray, NSUInteger outputArrayCount) //the list of all output specs
{
    printf("Connecting all dynamic inputs\n");
    
    clock_t begin = clock();
    size_t all_input_count = 0;
    size_t static_input_count = 0;

	for(TaskProxy *one_medusa in all_medusas)
	{
        bool are_all_inputs_satisfied = true;
        for(PathSpec *input_spec in one_medusa.inputs)
        {
         	all_input_count++;
            
            //find if this medusa's input is known to be produced by another one
            NSUInteger producer_index = (NSUInteger)CFDictionaryGetValue(output_paths_to_producer_indexes, (const void *)input_spec.path);
            assert(input_spec.producerIndex == 0);
            if(producer_index != 0) //0 is a reserved index for static inputs
            {
                input_spec.producerIndex = producer_index; //for easy lookup later in output_producers
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

