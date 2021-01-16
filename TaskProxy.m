//
//  TaskProxy.m
//
//  Created by Tomasz Kukielka on 9/20/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TaskProxy.h"
#include "LogStream.h"

extern dispatch_queue_t sQueue;
extern dispatch_group_t sGroup;

//#define TRACE_PROXY 1

@interface TaskProxy()
	@property(nonatomic, strong) NSMutableSet<TaskProxy*> *nextTasks;
	@property(nonatomic, strong) dispatch_block_t taskBlock;
	@property(nonatomic) NSInteger pendingDependenciesCount;
@end

@implementation TaskProxy

- (id)initWithTask:(dispatch_block_t)task
{
	self = [super init];
	if(self != nil)
	{
		_taskBlock = task;
		_pendingDependenciesCount = 0;
		_executed = false;
	}

#if TRACE_PROXY
	printf("init proxy = %p\n", (__bridge void *)self);
#endif

	return self;
}

#if 0
- (BOOL)taskExistsInNextTaskTree:(TaskProxy*)task
{
	if(self == task)
		return YES;

	__block BOOL isFound = NO;
	if(_nextTasks != nil)
	{
		__weak TaskProxy* weakTask = task;
		[_nextTasks enumerateObjectsUsingBlock:^(TaskProxy * _Nonnull obj, BOOL * _Nonnull stop) {
			isFound = [obj taskExistsInNextTaskTree:weakTask];
			if(isFound)
				*stop = YES;
		}];
	}

	return isFound;
}
#endif

- (void)linkNextTask:(TaskProxy*)nextTask
{
	assert(nextTask != nil);
	// never add self as a dependency of self or this will result in circular dependency
	// and this task will never be dispatched (its dependency count will not reach 0)
	if(nextTask == self)
		return;

	if(_nextTasks == nil)
	{
		_nextTasks = [[NSMutableSet<TaskProxy*> alloc] init];
	}

#if 0 //too expensive for non-trivial graphs
	// verify that this task is not in a list of the nextTask's nextTasks
	// next task depends on this one, so this task cannot already exist in downstream tree of the next task
	BOOL isCircularDependency = [nextTask taskExistsInNextTaskTree:self];
	if(isCircularDependency)
	{
		fprintf(gLogErr, "error: circular dependency has been detected in the action graph.\n");
		safe_exit(EXIT_FAILURE);
	}
#endif

	//it is a bummer we have to use two calls to the collection to learn if the the object to insert is unique
	//CoreFoundation or Foundation collections do not return value indicating if inserted object is unique
	//or if it was there already
	if(![_nextTasks containsObject:nextTask])
	{
		[_nextTasks addObject:nextTask];
		[nextTask incrementDependencyCount]; //this task (self) is the dependency for the new nextTask
	}
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
		assert(_pendingDependenciesCount >= 0); // programmer error if it goes below 0
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
		// there must be no mistake in algorithm
		// no matter what, the task in graph can only be executed once
		assert(!_executed);

		//execute the actual requested task now
		_taskBlock();

		_executed = true;
		
		// we don't release _taskBlock here
		// because freeing memory from background threads has a big perf penalty

		//when we are done executing, tell all nextTasks there is one less dependency to wait on
		for(TaskProxy *nextTask in _nextTasks)
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

#if ENABLE_DEBUG_DUMP

- (void)dumpDescription
{
	printf("TaskProxy self=%p\n", (__bridge void *)self);
	
	printf("  inputs:\n");
	for(NSUInteger i = 0; i < _inputCount; i++)
	{
		printf("    ");
		DumpBranchForNode(_inputs[i]);
	}

	printf("  outputs:\n");
	for(NSUInteger i = 0; i < _outputCount; i++)
	{
		printf("    ");
		DumpBranchForNode(_outputs[i]);
	}
}
#endif //ENABLE_DEBUG_DUMP

- (void)describeTaskToStdErr
{
	char path[2048];

	NSString *actionName = self.stepDescription[@"action"];
	fprintf(gLogErr, "[%s]\n", actionName.UTF8String);
	fprintf(gLogErr, "  unsatisfied dependency count: %ld\n", _pendingDependenciesCount);

	fprintf(gLogErr, "  inputs:\n");
	for(NSUInteger i = 0; i < _inputCount; i++)
	{
		GetPathForNode(_inputs[i], path, sizeof(path));
		fprintf(gLogErr, "    %s\n", path);
	}

	fprintf(gLogErr, "  outputs:\n");
	for(NSUInteger i = 0; i < _outputCount; i++)
	{
		GetPathForNode(_outputs[i], path, sizeof(path));
		fprintf(gLogErr, "    %s\n", path);
	}
}

@end //@implementation TaskProxy

