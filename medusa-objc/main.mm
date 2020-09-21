//
//  main.m
//  medusa-objc
//
//  Created by Tomasz Kukielka on 9/13/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "RecursiveMedusa.h"
#import "SchedulerMedusa.h"
#import "MedusaTaskProxy.h"
#import "TaskScheduler.h"

#include <iostream>
#include <random>
#include "hi_res_timer.h"

//#define PRINT_TASK 1
#define TEST_RECURSIVE 1

static NSArray< id<MedusaTask> > * GenerateTestMedusaTasks(
									Class TaskClass,
									NSUInteger medusa_count,
                                    size_t max_static_input_count, //>0
                                    size_t max_dynamic_input_count, //>=0
                                    size_t max_output_count, //>0
                                    NSUInteger *inputCountPtr,
                                    NSUInteger *outputCountPtr)
{
    std::cout << "Generating " << medusa_count << " test medusas\n";
    hi_res_timer timer;
    NSMutableArray< id<MedusaTask> > *test_medusas = [[NSMutableArray alloc] initWithCapacity:medusa_count];

	NSUInteger inputCount = 0;
	NSUInteger outputCount = 0;

    std::random_device randomizer;
    assert(max_static_input_count > 0);
    std::uniform_int_distribution<size_t> static_input_distibution(1, max_static_input_count-1);
    std::uniform_int_distribution<size_t> dynamic_input_distibution(0, max_dynamic_input_count-1);
    assert(max_output_count > 0);
    std::uniform_int_distribution<size_t> output_distibution(1, max_output_count-1);

    for(size_t i = 0; i < medusa_count; i++)
    {
        size_t static_input_count = static_input_distibution(randomizer);
        //don't bother adding dynamic inputs to lower count medusas until we get enough static-only ones with some outputs to use
        size_t dynamic_input_count = (i < max_dynamic_input_count) ? 0 : dynamic_input_distibution(randomizer);
        size_t output_count = output_distibution(randomizer);
        
        MedusaTaskProxy *one_medusa = [[TaskClass alloc] initWithTask:^{
#if PRINT_TASK
        	printf("executing medusa %lu\n", i);
#endif
		}];
        [test_medusas addObject:one_medusa];
        
        one_medusa.inputs = [[NSMutableArray alloc] initWithCapacity:static_input_count+dynamic_input_count];
        for(size_t j = 0; j < static_input_count; j++)
        {
            NSString *path = [[NSString alloc] initWithFormat:@"S%lu", (i*1000 + j)];
            PathSpec *pathSpec = [[PathSpec alloc] initWithPath:path];
            [one_medusa.inputs addObject:pathSpec];
            inputCount++;
        }

        //dynamic inputs are chosen at random from medusas with lower indexes
        
        for(size_t j = 0; j < dynamic_input_count; j++)
        {
            //pick at random some output from a lower-index medusa
            size_t lower_medusa_index = 0;
            size_t lower_medusa_output_count = 0;
            std::uniform_int_distribution<size_t> lower_medusa_distibution(0, i-1);
            do
            {
                lower_medusa_index = lower_medusa_distibution(randomizer);
				id<MedusaTask> lower_medusa = test_medusas[lower_medusa_index];
                lower_medusa_output_count = lower_medusa.outputs.count;
            } while(lower_medusa_output_count == 0);

            //TODO: this generator allows putting the same dynamic inputs more than once (does not matter with larger numeber of medusas)
            std::uniform_int_distribution<size_t> lower_medusa_output_distribution(0, lower_medusa_output_count-1);
            size_t lower_medusa_output_index = lower_medusa_output_distribution(randomizer);
            NSString *path = [[NSString alloc] initWithFormat:@"D%lu", (lower_medusa_index*1000 + lower_medusa_output_index)];
            PathSpec *pathSpec = [[PathSpec alloc] initWithPath:path];
            [one_medusa.inputs addObject:pathSpec];
            inputCount++;
        }

        one_medusa.outputs = [[NSMutableArray alloc] initWithCapacity:output_count];

        for(size_t j = 0; j < output_count; j++)
        {
            NSString *path = [[NSString alloc] initWithFormat:@"D%lu", (i*1000 + j)];
            PathSpec *pathSpec = [[PathSpec alloc] initWithPath:path];
            [one_medusa.outputs addObject:pathSpec];
            outputCount++;
        }
    }

    double seconds_core = timer.elapsed();

    for (NSUInteger i = 0; i < (medusa_count-1); i++)
    {
		std::uniform_int_distribution<size_t> remaining_items_distibution(0, medusa_count-i-1);
		size_t randomIndex = remaining_items_distibution(randomizer);
        [test_medusas exchangeObjectAtIndex:i withObjectAtIndex:(i+randomIndex)];
    }

    double seconds_shuffled = timer.elapsed();

    std::cout << "Finished medusa generation in " << seconds_shuffled << " seconds\n";
    std::cout << "Shuffled generated medusas in " << (seconds_shuffled - seconds_core) << " seconds\n";

	if(inputCountPtr != NULL)
		*inputCountPtr = inputCount;

	if(outputCountPtr != NULL)
		*outputCountPtr = outputCount;

    return test_medusas;
}

static void ExecuteMedusasRecursively(NSArray<MedusaTaskProxy *> *all_medusas, NSUInteger inputCount, NSUInteger outputCount)
{
	//keys are CFStrings/NSStrings output paths
	//values are NSUInteger indexes to producers in output_producers array
	CFMutableDictionaryRef output_paths_to_producer_indexes = ::CFDictionaryCreateMutable(
										kCFAllocatorDefault,
										0,
										&kCFTypeDictionaryKeyCallBacks,//keyCallBacks,
										NULL ); //value callbacks

	OutputInfo *outputInfoArray = (OutputInfo *)calloc(outputCount, sizeof(OutputInfo));
	
	IndexAllOutputsForRecursiveExecution(all_medusas, output_paths_to_producer_indexes, outputInfoArray, outputCount);

	//medusas without dynamic dependencies to be executed first - produced by this call
	NSArray<MedusaTaskProxy *> *static_inputs_medusas = ConnectDynamicInputsForRecursiveExecution(
										all_medusas, //input list of all raw unconnected medusas
										output_paths_to_producer_indexes, //the helper map produced in first pass
										outputInfoArray, outputCount);  //the list of all output specs

	std::cout << "Following medusa chain recursively\n";
	hi_res_timer timer;
	ExecuteMedusaGraphRecursively(static_inputs_medusas, outputInfoArray, outputCount);
	double seconds = timer.elapsed();
	std::cout << "Finished medusa execution in " << seconds << " seconds\n";
}

static void ExecuteMedusasWithScheduler(NSArray<TaskProxy*> *allTasks, NSUInteger inputCount, NSUInteger outputCount)
{
	//keys are CFStrings/NSStrings output paths
	//values are NSUInteger indexes to producers in output_producers array
	CFMutableDictionaryRef output_paths_to_producer_indexes = ::CFDictionaryCreateMutable(
										kCFAllocatorDefault,
										0,
										&kCFTypeDictionaryKeyCallBacks,//keyCallBacks,
										NULL ); //value callbacks

	__unsafe_unretained TaskProxy* *outputInfoArray = (__unsafe_unretained TaskProxy* *)calloc(outputCount, sizeof(TaskProxy*));
	
	IndexAllOutputsForScheduler(allTasks, output_paths_to_producer_indexes, outputInfoArray, outputCount);

	TaskScheduler *scheduler = [TaskScheduler sharedScheduler];

	//graph root task is created by the scheduler
	//we build the graph by adding children tasks to the root

	ConnectDynamicInputsForScheduler(
								allTasks, //input list of all raw unconnected medusas
								scheduler.rootTask,
								output_paths_to_producer_indexes, //the helper map produced in first pass
								outputInfoArray, outputCount);  //the list of all output specs

	free(outputInfoArray);

	std::cout << "Executing medusa chain with TaskScheduler\n";
	hi_res_timer timer;

	[scheduler startExecutionAndWait];
	 
	double seconds = timer.elapsed();
	std::cout << "Finished medusa execution in " << seconds << " seconds\n";
}


int main(int argc, const char * argv[])
{
    int err_code = 0;
	@autoreleasepool
	{
		NSUInteger totalInputCount = 0;
		NSUInteger totalOutputCount = 0;

#if TEST_RECURSIVE
		printf("Single-threaded recursive medusa algorithm\n\n");

   		NSArray< id<MedusaTask> > *testMedusas = GenerateTestMedusaTasks(
   															[MedusaTaskProxy class],
															1000000, // medusa_count,
                                                            20, // max_static_input_count > 0
                                                            20, // max_dynamic_input_count, //>=0
                                                            20,  // max_output_count > 0
                                                            &totalInputCount,
                                                            &totalOutputCount
                                                            );

		// it is a reasonable requirement for the medusa generator to give us the total input/output count upfront
		// it must have been processed already so we don't have to count again or adjust storage for items on the fly
		ExecuteMedusasRecursively((NSArray<MedusaTaskProxy *> *)testMedusas, totalInputCount, totalOutputCount);

		{
			hi_res_timer timer;
			testMedusas = nil;
			double seconds = timer.elapsed();
			std::cout << "Releasing all generated MedusaTaskProxy nodes took " << seconds << " seconds\n";
		}

		printf("\n\n--------------------------------\n");

#endif //TEST_RECURSIVE

		printf("Concurrent medusa algorithm with TaskScheduler\n\n");

  		NSArray< id<MedusaTask> > *scheduleMedusas = GenerateTestMedusaTasks(
   															[TaskProxy class],
															1000000, // medusa_count,
                                                            20, // max_static_input_count > 0
                                                            20, // max_dynamic_input_count, //>=0
                                                            20,  // max_output_count > 0
                                                            &totalInputCount,
                                                            &totalOutputCount
                                                            );

		ExecuteMedusasWithScheduler((NSArray<TaskProxy*> *)scheduleMedusas, totalInputCount, totalOutputCount);
		
		{
			hi_res_timer timer;
			scheduleMedusas = nil;
			double seconds = timer.elapsed();
			std::cout << "Releasing all generated TaskProxy nodes took " << seconds << " seconds\n";
		}

		// it looks like a lot of unnecessary Obj-C memory cleanup is happening at exit and takes long time
		// skip it and just terminate the app now
		exit(err_code);
	}
	return err_code;
}
