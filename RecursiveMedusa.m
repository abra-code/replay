//
//  RecursiveMedusa.m
//
//  Created by Tomasz Kukielka on 9/13/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import "RecursiveMedusa.h"
#import "MedusaTaskProxy.h"

//first pass
void IndexAllOutputsForRecursiveExecution(NSArray< id<MedusaTask> > *all_medusas,
						CFMutableDictionaryRef output_paths_to_producer_indexes,
                       	OutputInfo *outputInfoArray, NSUInteger outputArrayCount)
{
    printf("First pass to index all output files\n");
    clock_t begin = clock();
	NSUInteger outputIndex = 0;
	for( id<MedusaTask> one_medusa in all_medusas)
	{
        for(PathSpec *one_output in one_medusa.outputs)
        {
        	assert(outputIndex < outputArrayCount);
			OutputInfo* output_producer = &(outputInfoArray[outputIndex]);
			output_producer->producer = one_medusa;
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


//second pass - connect outputs to inputs, gather info about consumers and producers
//find first medusas without dependencies

NSArray<MedusaTaskProxy *> * //medusas without dynamic dependencies to be executed first - produced here
ConnectDynamicInputsForRecursiveExecution(NSArray<MedusaTaskProxy *> *all_medusas, //input list of all raw unconnected medusas
                       CFDictionaryRef output_paths_to_producer_indexes, //the helper map produced in first pass
                       OutputInfo *outputInfoArray, NSUInteger outputArrayCount)  //the list of all output specs
{
    printf("Connecting all dynamic inputs\n");
    
    clock_t begin = clock();
    size_t all_input_count = 0;
    size_t static_input_count = 0;

	NSMutableArray<MedusaTaskProxy *> *static_input_medusas = [[NSMutableArray alloc] initWithCapacity:0];

	for(MedusaTaskProxy *one_medusa in all_medusas)
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
                OutputInfo *outputInfo = &(outputInfoArray[producer_index-1]);
                if(outputInfo->consumers == nil)
	                outputInfo->consumers = [[NSMutableSet alloc] initWithCapacity:0];
                [outputInfo->consumers addObject:one_medusa];// add oneself to the list of consumers
            }
            else
            {
            	static_input_count++;
            }

            are_all_inputs_satisfied = (are_all_inputs_satisfied && (producer_index == 0));
        }
        
        if(are_all_inputs_satisfied)
        {
            //one_medusa.is_processed = true;
			[static_input_medusas addObject:one_medusa];
        }
    }
    
	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
    printf("Finished connecting all dynamic outputs in %f seconds\n", seconds);
    
    printf("All input count %lu\n", all_input_count);
    printf("Static input count %lu\n", static_input_count);
    printf("Initial count of medusas with static dependencies only: %lu\n", static_input_medusas.count);
    
    return static_input_medusas;
}


// This function executes recursively in much longer time than the corresponding C++ code in medusa3
// For example 1 million medusa test runs this one for 16-18 seconds compared to 7-8 seconds in C++.
// On the first look there is nothing that much expensive going on here and the same operations are perfomred in C++ on STL containers:
// - we have 4 nested container iterators
// - we have no dictionary lookups
// - we populate one medusa array for the next nested iteration
//

void ExecuteMedusaGraphRecursively(NSArray<MedusaTaskProxy *> *medusa_list, OutputInfo *outputInfoArray, NSUInteger outputArrayCount)
{
    NSMutableArray<MedusaTaskProxy *> *next_medusa_list = [[NSMutableArray alloc] initWithCapacity:0];
    for(MedusaTaskProxy *one_medusa in medusa_list)
	{
		// ****** EXECUTE ******
		[one_medusa executeTask];
		
		// consider one_medusa executed here

		for(PathSpec *output_spec in one_medusa.outputs)
        {
        	//mark all path specs coming out from this medusa as produced now
            size_t output_producer_index = output_spec.producerIndex;
            assert((output_producer_index > 0) && ((output_producer_index-1) < outputArrayCount));
            OutputInfo* output_producer = &(outputInfoArray[output_producer_index-1]);
            output_producer->built = true;

			// now look ahead at consuming nodes and check if all inputs are satisifed now
			for(MedusaTaskProxy *consumer_medusa in output_producer->consumers)
			{
				bool are_all_inputs_satisfied = true;
				
				for(PathSpec *consumer_input_spec in consumer_medusa.inputs)
				{
					size_t producerIndex = consumer_input_spec.producerIndex;
					bool is_input_satisfied = (producerIndex == 0); //index 0 is static
					if(!is_input_satisfied)
					{
						assert((producerIndex-1) < outputArrayCount);
						OutputInfo* oneProducer = &(outputInfoArray[producerIndex-1]);
						//check if the producer for this input has been executed already
						is_input_satisfied = oneProducer->built;
					}
					are_all_inputs_satisfied = (are_all_inputs_satisfied && is_input_satisfied);
					if(!are_all_inputs_satisfied)
						break;
				}

				if(are_all_inputs_satisfied)
				{
					//consumer_medusa.is_processed = true;
					[next_medusa_list addObject:consumer_medusa];
				}
			}
        }
    }

    if(next_medusa_list.count > 0)
    {
        //now recursively go over next medusas and follow the outputs to find the ones with all satisifed inputs
        ExecuteMedusaGraphRecursively(next_medusa_list, outputInfoArray, outputArrayCount);
    }
    else
    {
        // std::cout << "No more medusas with all satsfied inputs found. Done\n";
    }
}
