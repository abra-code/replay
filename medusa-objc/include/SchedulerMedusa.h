//
//  SchedulerMedusa.h
//
//  Created by Tomasz Kukielka on 9/20/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TaskProxy.h"

void
ConnectImplicitProducers(FileNode *treeRoot);

void
ConnectDynamicInputsForScheduler(NSArray< id<MedusaTask> > *all_medusas, //input list of all raw unconnected medusas
								TaskProxy *rootTask);

void
ConnectGlobDependencies(NSArray<TaskProxy*> *allTasks);
