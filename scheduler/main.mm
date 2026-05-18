//
//  main.mm
//  scheduler
//
//  Created by Tomasz Kukielka on 9/5/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#include "TaskScheduler.h"
#include "TaskProxy.h"
#include "../common/include/ReplaySignpost.h"
#include <cstdio>
#include <ctime>
#include <memory>
#include <vector>

// 3,300,000 empty dispatched blocks peaked at about 200MB heap consumption
// The cost of the graph itself is 167MB and then it grows some more when dispatching starts
// Time spent executing these empty tasks on MacBook Pro 2.7 GHz Quad-Core Intel Core i7
// was about 18-20 seconds on average, or about 6 seconds per 1 million tasks (ship build, no debugger)
//
// However, if we don't start releasing the graph nodes right after the dispatch
// the execution time dramatically drops to 6.5-6.8s - almost 3x! - 2 seconds per 1 million tasks
// Profiling shows that freeing memory on multiple threads incurs a huge locking cost
// The heap allocations without releasing the graph early peaked at 250MB, or 25% increase
//
// It is a clear performance win over a relatively moderate memory overhead to not start releasing
// the graph nodes on secondary threads after each task is done.

//#define EXECUTE_PRINT 1

int main(int argc, const char * argv[])
{
	printf("scheduler: constructing graph\n");
	REPLAY_SIGNPOST_EVENT("Constructing graph");
	clock_t begin = clock();

	// Owns all task nodes; raw pointers used in the graph.
	std::vector<std::unique_ptr<TaskProxy>> ownedTasks;

	auto makeTask = [&](auto block) -> TaskProxy* {
		auto t = std::make_unique<TaskProxy>(std::move(block));
		TaskProxy* raw = t.get();
		ownedTasks.push_back(std::move(t));
		return raw;
	};

	TaskScheduler scheduler(0 /*unlimited*/);
	TaskProxy* taskGraphRoot = scheduler.rootTask();

	for(int i = 0; i < 1000; i++)
	{
		TaskProxy* taskLevelOne = makeTask([i]() {
#if EXECUTE_PRINT
			printf("executing task: level=1 i=%d\n", i);
#endif
		});
		taskGraphRoot->linkNextTask(taskLevelOne);

		for(int j = 0; j < 1000; j++)
		{
			TaskProxy* taskLevelTwo = makeTask([i, j]() {
#if EXECUTE_PRINT
				printf("executing task: level=2 i=%d j=%d\n", i, j);
#endif
			});
			taskLevelOne->linkNextTask(taskLevelTwo);

			TaskProxy* taskLevel3A = makeTask([i, j]() {
#if EXECUTE_PRINT
				printf("executing task: level=3A i=%d j=%d\n", i, j);
#endif
			});
			taskLevelTwo->linkNextTask(taskLevel3A);

			TaskProxy* taskLevel3B = makeTask([i, j]() {
#if EXECUTE_PRINT
				printf("executing task: level=3B i=%d j=%d\n", i, j);
#endif
			});
			taskLevelTwo->linkNextTask(taskLevel3B);
		}
	}

	clock_t end_construction = clock();
	double time_spent = (double)(end_construction - begin) / CLOCKS_PER_SEC;
	printf("scheduler: time spent constructing graph: %f\n", time_spent);

	REPLAY_SIGNPOST_EVENT("Starting graph execution");
	printf("scheduler: starting graph execution\n");

	scheduler.startExecutionAndWait();

	clock_t end_execution = clock();
	time_spent = (double)(end_execution - end_construction) / CLOCKS_PER_SEC;
	printf("scheduler: done waiting in dispatch_group_wait()\n");
	printf("scheduler: time spent executing tasks: %f\n", time_spent);

	return 0;
}
