//
//  RecursiveMedusa.h
//
//  Created by Tomasz Kukielka on 9/13/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "MedusaTask.h"

@class MedusaTaskProxy;

typedef struct OutputInfo
{
	__unsafe_unretained id<MedusaTask> producer;
	__strong NSMutableSet< id<MedusaTask> > *consumers; //consumers of this one output
	bool built;
} OutputInfo;

#ifdef __cplusplus
extern "C" {
#endif

void IndexAllOutputsForRecursiveExecution(NSArray< id<MedusaTask> > *all_medusas,
						CFMutableDictionaryRef output_paths_to_indexes_map,
                       	OutputInfo *outputInfoArray, NSUInteger outputArrayCount);

NSArray<MedusaTaskProxy *> * //medusas without dynamic dependencies to be executed first produced here
ConnectDynamicInputsForRecursiveExecution(NSArray<MedusaTaskProxy *> *all_medusas, //input list of all raw unconnected medusas
						CFDictionaryRef output_paths_to_producer_indexes, //the helper map produced in first pass
						OutputInfo *outputInfoArray, NSUInteger outputArrayCount); //the list of all output specs

void ExecuteMedusaGraphRecursively(NSArray<MedusaTaskProxy *> *medusa_list, OutputInfo *outputInfoArray, NSUInteger outputArrayCount);


#ifdef __cplusplus
}
#endif
