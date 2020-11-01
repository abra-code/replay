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
#include "FileTree.h"

#include <iostream>
#include <random>
#include "hi_res_timer.h"

static inline FileNode * FileNodeFromPath(FileNode *fileTreeRoot, NSString *path)
{
	NSString *lowercasePath = [path lowercaseString];
	const char *posixPath = [lowercasePath fileSystemRepresentation];
	return FindOrInsertFileNodeForPath(fileTreeRoot, posixPath);
}

//#define PRINT_TASK 1
#define TEST_RECURSIVE 1

static NSArray< id<MedusaTask> > * GenerateTestMedusaTasks(
									Class TaskClass,
									FileNode *fileTreeRoot,
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
        
        uint64_t input_count = static_input_count + dynamic_input_count;
        FileNode** input_array = (FileNode**)malloc(sizeof(FileNode*) * input_count);

        for(size_t j = 0; j < static_input_count; j++)
        {
            NSString *path = [[NSString alloc] initWithFormat:@"/Static/Dir-%lu/File-%lu", i, (i*1000 + j)];
			FileNode *node = FileNodeFromPath(fileTreeRoot, path);
			input_array[j] = node;
            inputCount++;
        }
        
        one_medusa.inputCount = input_count;
		one_medusa.inputs = input_array;

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
                lower_medusa_output_count = lower_medusa.outputCount;
            } while(lower_medusa_output_count == 0);

            //TODO: this generator allows putting the same dynamic inputs more than once (does not matter with larger number of medusas)
            std::uniform_int_distribution<size_t> lower_medusa_output_distribution(0, lower_medusa_output_count-1);
            size_t lower_medusa_output_index = lower_medusa_output_distribution(randomizer);
            NSString *path = [[NSString alloc] initWithFormat:@"/Dynamic/Dir-%lu/Out-%lu", lower_medusa_index, (lower_medusa_index*1000 + lower_medusa_output_index)];
			FileNode *node = FileNodeFromPath(fileTreeRoot, path);
			input_array[static_input_count+j] = node;
            inputCount++;
        }

		FileNode** output_array = (FileNode**)malloc(sizeof(FileNode*) * output_count);

        for(size_t j = 0; j < output_count; j++)
        {
            NSString *path = [[NSString alloc] initWithFormat:@"/Dynamic/Dir-%lu/Out-%lu", i, (i*1000 + j)];
			FileNode *node = FileNodeFromPath(fileTreeRoot, path);
			output_array[j] = node;
            outputCount++;
        }
        
		one_medusa.outputCount = output_count;
		one_medusa.outputs = output_array;
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
	OutputInfo *outputInfoArray = (OutputInfo *)calloc(outputCount, sizeof(OutputInfo));
	
	IndexAllOutputsForRecursiveExecution(all_medusas, outputInfoArray, outputCount);

	//medusas without dynamic dependencies to be executed first - produced by this call
	NSArray<MedusaTaskProxy *> *static_inputs_medusas = ConnectDynamicInputsForRecursiveExecution(
										all_medusas, //input list of all raw unconnected medusas
										outputInfoArray, outputCount);  //the list of all output specs

	std::cout << "Following medusa chain recursively\n";
	hi_res_timer timer;
	ExecuteMedusaGraphRecursively(static_inputs_medusas, outputInfoArray, outputCount);
	double seconds = timer.elapsed();
	std::cout << "Finished medusa execution in " << seconds << " seconds\n";
}

static void ExecuteMedusasWithScheduler(NSArray<TaskProxy*> *allTasks, NSUInteger inputCount, NSUInteger outputCount)
{
	__unsafe_unretained TaskProxy* *outputInfoArray = (__unsafe_unretained TaskProxy* *)calloc(outputCount, sizeof(TaskProxy*));
	
	IndexAllOutputsForScheduler(allTasks, outputInfoArray, outputCount);

	TaskScheduler *scheduler = [TaskScheduler sharedScheduler];

	//graph root task is created by the scheduler
	//we build the graph by adding children tasks to the root

	ConnectDynamicInputsForScheduler(
								allTasks, //input list of all raw unconnected medusas
								scheduler.rootTask,
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
	{
		printf("Single-threaded recursive medusa algorithm\n\n");

		FileNode *fileTreeRoot = CreateFileTreeRoot();
   		NSArray< id<MedusaTask> > *testMedusas = GenerateTestMedusaTasks(
   															[MedusaTaskProxy class],
   															fileTreeRoot,
															500000, // medusa_count,
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
	}
#endif //TEST_RECURSIVE

		FileNode *fileTreeRoot = CreateFileTreeRoot();
		printf("Concurrent medusa algorithm with TaskScheduler\n\n");

  		NSArray< id<MedusaTask> > *scheduleMedusas = GenerateTestMedusaTasks(
   															[TaskProxy class],
   															fileTreeRoot,
															500000, // medusa_count,
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
