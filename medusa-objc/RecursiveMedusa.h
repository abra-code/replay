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
} OutputInfo;

#ifdef __cplusplus
extern "C" {
#endif

void IndexAllOutputsForRecursiveExecution(NSArray< id<MedusaTask> > *all_medusas,
                       	OutputInfo *outputInfoArray, NSUInteger outputArrayCount);

void ConnectImplicitProducersForRecursiveExecution(FileNode *treeRoot);

NSSet<MedusaTaskProxy *> * //medusas without dynamic dependencies to be executed first produced here
ConnectDynamicInputsForRecursiveExecution(NSArray<MedusaTaskProxy *> *allTasks); //input list of all raw unconnected medusas

void ExecuteMedusaGraphRecursively(NSSet<MedusaTaskProxy *> *taskSet);

#if ENABLE_DEBUG_DUMP
void DumpRecursiveTaskTree(NSSet<MedusaTaskProxy *> *rootTaskSet);
#endif

#ifdef __cplusplus
}
#endif
