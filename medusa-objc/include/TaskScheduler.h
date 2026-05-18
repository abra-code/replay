#pragma once
#include "TaskProxy.h"
#include <memory>

// Thin scheduler shell: owns the root sentinel task and drives graph execution.
// User tasks are owned by the caller; this object only owns rootTask_.
class TaskScheduler {
public:
	explicit TaskScheduler(intptr_t concurrencyLimit);

	TaskProxy* rootTask() const { return rootTask_.get(); }
	void startExecutionAndWait();

private:
	std::unique_ptr<TaskProxy> rootTask_;
};
