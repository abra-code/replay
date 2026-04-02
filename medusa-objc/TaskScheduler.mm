//
//  TaskScheduler.m
//
//  Created by Tomasz Kukielka on 9/5/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TaskScheduler.h"
#import "TaskProxy.h"
#import "AsyncDispatch.h"

// private contract between TaskScheduler and TaskProxy:

@interface TaskProxy()
	- (void)incrementDependencyCount __attribute__((objc_direct));
	- (void)decrementDependencyCount __attribute__((objc_direct));
@end


@implementation TaskScheduler

-(instancetype) initWithConcurrencyLimit:(intptr_t)concurrencyLimit __attribute__((objc_direct))
{
	self = [super init];
	if(self != nil)
	{
		StartAsyncDispatch(concurrencyLimit);

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

- (void)startExecutionAndWait __attribute__((objc_direct))
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

	FinishAsyncDispatchAndWait();
}

@end //@implementation TaskScheduler

