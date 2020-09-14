//
//  main.m
//  medusa-objc
//
//  Created by Tomasz Kukielka on 9/13/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "Medusa.h"
#include <iostream>
#include <random>
#include "hi_res_timer.h"


static NSArray<Medusa *> * generate_test_medusas(NSUInteger medusa_count,
                                    size_t max_static_input_count, //>0
                                    size_t max_dynamic_input_count, //>=0
                                    size_t max_output_count) //>0
{
    std::cout << "Generating " << medusa_count << " test medusas\n";
    hi_res_timer timer;
    NSMutableArray<Medusa *> *test_medusas = [[NSMutableArray alloc] initWithCapacity:medusa_count];

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
        
        Medusa *one_medusa = [[Medusa alloc] init];
        [test_medusas addObject:one_medusa];
        
        one_medusa.inputs = [[NSMutableArray alloc] initWithCapacity:static_input_count+dynamic_input_count];
        for(size_t j = 0; j < static_input_count; j++)
        {
            NSString *path = [[NSString alloc] initWithFormat:@"S%lu", (i*1000 + j)];
            PathSpec *pathSpec = [[PathSpec alloc] initWithPath:path];
            [one_medusa.inputs addObject:pathSpec];
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
				Medusa *lower_medusa = test_medusas[lower_medusa_index];
                lower_medusa_output_count = lower_medusa.outputs.count;
            } while(lower_medusa_output_count == 0);

            //TODO: this generator allows putting the same dynamic inputs more than once (does not matter with larger numeber of medusas)
            std::uniform_int_distribution<size_t> lower_medusa_output_distribution(0, lower_medusa_output_count-1);
            size_t lower_medusa_output_index = lower_medusa_output_distribution(randomizer);
            NSString *path = [[NSString alloc] initWithFormat:@"D%lu", (lower_medusa_index*1000 + lower_medusa_output_index)];
            PathSpec *pathSpec = [[PathSpec alloc] initWithPath:path];
            [one_medusa.inputs addObject:pathSpec];
        }

        one_medusa.outputs = [[NSMutableArray alloc] initWithCapacity:output_count];

        for(size_t j = 0; j < output_count; j++)
        {
            NSString *path = [[NSString alloc] initWithFormat:@"D%lu", (i*1000 + j)];
            PathSpec *pathSpec = [[PathSpec alloc] initWithPath:path];
            [one_medusa.outputs addObject:pathSpec];
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

    std::cout << "Shuffled generated medusas in " << (seconds_shuffled - seconds_core) << " seconds\n";
    std::cout << "Finished medusa generation in " << seconds_shuffled << " seconds\n";

    return test_medusas;
}

static void conect_medusas_objc(NSArray<Medusa *> *all_medusas)
{
	//keys are CFStrings/NSStrings output paths
	//values are NSUInteger indexes to producers in output_producers array
	CFMutableDictionaryRef output_paths_to_producer_indexes = ::CFDictionaryCreateMutable(
										kCFAllocatorDefault,
										0,
										&kCFTypeDictionaryKeyCallBacks,//keyCallBacks,
										NULL ); //value callbacks

	NSMutableArray<OutputProducer*> *output_producers = [[NSMutableArray alloc] initWithCapacity:0];
	
	index_all_outputs(all_medusas, output_paths_to_producer_indexes, output_producers);

	//medusas without dynamic dependencies to be executed first - produced by this call
	NSMutableArray<Medusa *> *static_inputs_medusas = connect_all_dynamic_inputs(
										all_medusas, //input list of all raw unconnected medusas
										output_paths_to_producer_indexes, //the helper map produced in first pass
										output_producers);  //the list of all output specs

	std::cout << "Following medusa chain recursively\n";
	hi_res_timer timer;
	execute_medusa_list(static_inputs_medusas, output_producers);
	double seconds = timer.elapsed();
	std::cout << "Finished medusa execution in " << seconds << " seconds\n";
}

int main(int argc, const char * argv[])
{
    int err_code = 0;
	@autoreleasepool
	{
   		NSArray<Medusa *> *all_medusas = generate_test_medusas( 1000000, // medusa_count,
                                                            20, // max_static_input_count > 0
                                                            20, // max_dynamic_input_count, //>=0
                                                            20  // max_output_count > 0
                                                            );

		conect_medusas_objc(all_medusas);

		//it looks like a lot of unnecessary Obj-C memory cleanup is happening at exit and takes long time
		//skip it and just reminate the app now
		exit(err_code);
	}
	return err_code;
}
