//
//  main.m
//  scheduler
//
//  Created by Tomasz Kukielka on 9/5/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TaskScheduler.h"
#import "TaskProxy.h"

@import os.signpost;

// 3,300,000 empty dispatched blocks peaked at about 200MB heap consumption
// The cost of the graph itself is 167MB and then it grows some more when dispatching starts
// Time spent executing these empty tasks on MacBook Pro 2.7 GHz Quad-Core Intel Core i7
// was about 18-20 seconds on average, or about 6 seconds per 1 million tasks (ship build, no debugger)
//
// However, if we don't start releasing the graph nodes right after the dispatch
// the execution time dramatically drops to 6.5-6.8s - almost 3x! - 2 seconds per 1 million tasks
// Profiling shows that freeing memory on multiple threads incures a huge locking cost
// The heap allocations without releasing the graph early peaked at 250MB, or 25% increase
//
// Removing @autoreleasepool blocks around the task execution and the root one in main
// do not seem to have an impact on execution time.
// With more complex blocks actually dispatched this may make a difference
//
// It is a clear performace win over a relatively moderate memory overhead to not start releasing
// the graph nodes on secondary threads after each task is done, therefore RELASE_GRAPH_EARLY is 0

#define RELASE_GRAPH_EARLY 0


//#define EXECUTE_PRINT 1

int main(int argc, const char * argv[])
{
	@autoreleasepool
	{
		os_log_t log = os_log_create("scheduler", OS_LOG_CATEGORY_POINTS_OF_INTEREST);

	    printf("scheduler: constructing graph\n");
	    os_signpost_event_emit(log, OS_SIGNPOST_ID_EXCLUSIVE, "Constructing graph");
		clock_t begin = clock();

		TaskScheduler *scheduler = [TaskScheduler new];
		
		//graph root task is created by the scheduler
		//we build the graph by adding children tasks to the root
		TaskProxy *taskGraphRoot = scheduler.rootTask;

		// construct the graph to execute
		// add 100 tasks with no dependencies
		// (other than the start node)
		for(int i=0; i <1000; i++)
		{
			TaskProxy *taskLevelOne = [[TaskProxy alloc] initWithTask:^{
#if EXECUTE_PRINT
					printf("executing task: level=1 i=%d\n", i);
#endif
				}];
			[taskGraphRoot linkNextTask:taskLevelOne];

			//add 100 tasks depending on each 1st level task
			for(int j=0; j <1000; j++)
			{
				TaskProxy *taskLevelTwo = [[TaskProxy alloc] initWithTask:^{
#if EXECUTE_PRINT
					printf("executing task: level=2 i=%d j=%d\n", i, j);
#endif
				}];
				[taskLevelOne linkNextTask:taskLevelTwo];
				
				//add 2 leaf tasks for each level 2 tasks
				TaskProxy *taskLevel3A = [[TaskProxy alloc] initWithTask:^{
#if EXECUTE_PRINT
					printf("executing task: level=3A i=%d j=%d\n", i, j);
#endif
				}];
				[taskLevelTwo linkNextTask:taskLevel3A];
				
				TaskProxy *taskLevel3B = [[TaskProxy alloc] initWithTask:^{
#if EXECUTE_PRINT
					printf("executing task: level=3B i=%d j=%d\n", i, j);
#endif
				}];
				[taskLevelTwo linkNextTask:taskLevel3B];
			}
		}

		clock_t end_construction = clock();
		double time_spent = (double)(end_construction - begin) / CLOCKS_PER_SEC;
	    printf("scheduler: time spent constructing graph: %f\n", time_spent);

	    os_signpost_event_emit(log, OS_SIGNPOST_ID_EXCLUSIVE, "Starting graph execution");
	    printf("scheduler: starting graph execution\n");

#if RELASE_GRAPH_EARLY
		// Release the root node
		// Dispatched block captures TaskProxy object [self] strongly
		// so after execution it should reach 0 refcount and get deallocated
		// See the discussion above RELASE_GRAPH_EARLY definition
		taskGraphRoot = nil;
#endif

	    [scheduler startExecutionAndWait];

		clock_t end_execution = clock();
		time_spent = (double)(end_execution - end_construction) / CLOCKS_PER_SEC;
		printf("scheduler: done waiting in dispatch_group_wait()\n");
	    printf("scheduler: time spent executing tasks: %f\n", time_spent);
	}
	return 0;
}
