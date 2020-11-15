//
//  TaskScheduler.m
//
//  Created by Tomasz Kukielka on 9/5/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TaskScheduler.h"
#import "TaskProxy.h"

dispatch_queue_t sQueue = nil;
dispatch_group_t sGroup = nil;

// private contract between TaskScheduler and TaskProxy:

@interface TaskProxy()
	- (void)incrementDependencyCount;
	-(void)decrementDependencyCount;
@end


static TaskScheduler *sSharedScheduler = nil;

@implementation TaskScheduler

+ (TaskScheduler *)sharedScheduler
{
	if(sSharedScheduler == nil)
	{
		sQueue = dispatch_queue_create("scheduler.concurrent.queue", DISPATCH_QUEUE_CONCURRENT);
		sGroup = dispatch_group_create();
		sSharedScheduler = [[TaskScheduler alloc] init];
	}
	return sSharedScheduler;
}

-(instancetype) init
{
	self = [super init];
	if(self != nil)
	{
		// the empty root task, its purpose it is to trigger the dispatch
		// of the first level of tasks without dependencies
		_rootTask = [[TaskProxy alloc] initWithTask:^{
				//printf("executing root node\n");
			}];

		// The implicit dependency task for root node is graph construction
		// After it is done, we invoke decrementDependencyCount
		// to start the graph execution
		[_rootTask incrementDependencyCount];
	}
	return self;
}

- (void)startExecutionAndWait
{
	//this starts the graph execution by reaching 0 dependecy count in _rootTask
	[_rootTask decrementDependencyCount];

#if RELASE_GRAPH_EARLY
	// Release the root node
	// Dispatched block captures TaskProxy object [self] strongly
	// so after execution it should reach 0 refcount and get deallocated
	// See the discussion above RELASE_GRAPH_EARLY definition
	_rootTask = nil;
#endif

	dispatch_group_wait(sGroup, DISPATCH_TIME_FOREVER);
}

@end //@implementation TaskScheduler

