//
//  SchedulerMedusa.h
//
//  Created by Tomasz Kukielka on 9/20/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TaskProxy.h"

#ifdef __cplusplus
extern "C" {
#endif

void IndexAllOutputsForScheduler(NSArray< id<MedusaTask> > *all_medusas,
						CFMutableDictionaryRef output_paths_to_indexes_map,
                       	__unsafe_unretained id<MedusaTask> *outputInfoArray, NSUInteger outputArrayCount);

void
ConnectDynamicInputsForScheduler(NSArray< id<MedusaTask> > *all_medusas, //input list of all raw unconnected medusas
						TaskProxy *rootTask,
						CFDictionaryRef output_paths_to_producer_indexes, //the helper map produced in first pass
						__unsafe_unretained id<MedusaTask> *outputInfoArray, NSUInteger outputArrayCount); //the list of all output specs

#ifdef __cplusplus
}
#endif
