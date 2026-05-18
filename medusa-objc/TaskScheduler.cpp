#include "TaskScheduler.h"
#include "AsyncDispatch.h"

TaskScheduler::TaskScheduler(intptr_t concurrencyLimit)
{
	StartAsyncDispatch(concurrencyLimit);

	// Empty root sentinel task — its sole purpose is to trigger the first wave
	// of tasks with no other dependencies once graph construction is done.
	rootTask_ = std::make_unique<TaskProxy>([](){});

	// Hold a synthetic dependency on behalf of graph construction.
	// Released by startExecutionAndWait() to kick off the whole graph.
	rootTask_->incrementDependencyCount();
}

void TaskScheduler::startExecutionAndWait()
{
	// Release the construction-hold on the root, starting the cascade.
	rootTask_->decrementDependencyCount();
	FinishAsyncDispatchAndWait();
}
