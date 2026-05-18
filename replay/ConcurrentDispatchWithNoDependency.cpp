#include "ConcurrentDispatchWithNoDependency.h"
#include "AsyncDispatch.h"

void
StartConcurrentDispatchWithNoDependency(ReplayContext *context)
{
	assert(context->concurrent);
	StartAsyncDispatch(context->councurrencyLimit);
}

void
FinishConcurrentDispatchWithNoDependencyAndWait(ReplayContext *context)
{
	FinishAsyncDispatchAndWait();
}

void
DispatchTasksConcurrentlyWithNoDependency(const std::vector<ActionStep>& playlist, ReplayContext *context)
{
	StartConcurrentDispatchWithNoDependency(context);

#if TRACE
	printf("start dispatching async tasks\n");
#endif

	for (const auto& step : playlist)
	{
		HandleActionStep(step, context,
			[](std::function<void()> action,
			__unused std::vector<std::string> inputs,
			__unused std::vector<std::string> mutatingInputs,
			__unused std::vector<std::string> exclusiveInputs,
			__unused std::vector<std::string> outputs)
			{
				if(action)
					AsyncDispatch(std::move(action));
			});
	}

#if TRACE
	printf("done dispatching async tasks\n");
#endif

	FinishConcurrentDispatchWithNoDependencyAndWait(context);
}

void
DispatchTaskConcurrentlyWithNoDependency(ActionStep step, ReplayContext *context)
{
	HandleActionStep(std::move(step), context,
		[](std::function<void()> action,
		__unused std::vector<std::string> inputs,
		__unused std::vector<std::string> mutatingInputs,
		__unused std::vector<std::string> exclusiveInputs,
		__unused std::vector<std::string> outputs)
		{
			if(action)
				AsyncDispatch(std::move(action));
		});
}
