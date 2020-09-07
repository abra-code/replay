//
//  TaskScheduler.m
//
//  Created by Tomasz Kukielka on 9/5/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TaskScheduler.h"

//#define TRACE_PROXY 1

static dispatch_queue_t sQueue = nil;
static dispatch_group_t sGroup = nil;

@interface TaskProxy()
	@property(nonatomic, strong) NSMutableArray<TaskProxy*> *nextTasks;
	@property(nonatomic, strong) dispatch_block_t taskBlock;
	@property(nonatomic) NSInteger pendingDependenciesCount;
@end

@implementation TaskProxy

- (id)initWithTask:(dispatch_block_t)task
{
	self = [super init];
	if(self != nil)
	{
		_pendingDependenciesCount = 0;
		_taskBlock = task;
	}

	return self;
}

- (void)linkNextTask:(TaskProxy*)nextTask
{
	if(_nextTasks == nil)
	{
		_nextTasks = [[NSMutableArray<TaskProxy*> alloc] init];
	}
	
	[_nextTasks addObject:nextTask];
	[nextTask incrementDependencyCount]; //our object is the dependency for the new nextTask
}

- (void)incrementDependencyCount
{
	@synchronized (self)
	{
		++_pendingDependenciesCount;
	}
}

// A task may have multiple dependencies
// They are incremented for the task during graph construction when you call linkNextTask:
// After each dependency has finished execution, it removes itself out of the picture
// and reduces the count in each downstream task which waits for it
// When the number of pending dependenices reaches 0
// it is a signal fot the task that it can be scheduled for execution and gets dispatched here
-(void)decrementDependencyCount
{
	@synchronized (self)
	{
		--_pendingDependenciesCount;
		if(_pendingDependenciesCount == 0)
		{//all dependencies satisfied, now we can execute our task
			//dispatch queue operations themselves are thread safe per Apple's documentation
			dispatch_group_async(sGroup, sQueue, ^{
				//self is captured strongly here by the block
				//at enqueueing time so callers with the last reference
				//are safe to release this object right after
				//calling [task decrementDependencyCount]
				[self executeTask];
			});
		}
	}
}

- (void)executeTask
{
#if TRACE_PROXY
	printf("executing proxy = %p\n", (__bridge void *)self);
#endif

	@autoreleasepool
	{
		//execute the actual requested task now
		_taskBlock();

		//when we are done executing, tell all nextTasks there is one less dependency to wait on
		for (TaskProxy *nextTask in _nextTasks)
		{
			[nextTask decrementDependencyCount];
		}
	}
}

#if TRACE_PROXY
-(void)dealloc
{
	 printf("dealloc proxy = %p\n", (__bridge void *)self);
}
#endif

@end //@implementation TaskProxy

#pragma mark -

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

