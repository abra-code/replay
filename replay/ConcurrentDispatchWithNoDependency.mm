#import "ConcurrentDispatchWithNoDependency.h"
#import "AsyncDispatch.h"

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
			^(dispatch_block_t action,
			__unused NSArray<NSString*> *inputs,
			__unused NSArray<NSString*> *mutatingInputs,
			__unused NSArray<NSString*> *exclusiveInputs,
			__unused NSArray<NSString*> *outputs)
			{
				if (action != NULL)
					AsyncDispatch(action);
			});
	}

#if TRACE
	printf("done dispatching async tasks\n");
#endif

	FinishConcurrentDispatchWithNoDependencyAndWait(context);
}

void
DispatchTaskConcurrentlyWithNoDependency(NSDictionary *stepDescription, ReplayContext *context)
{
	ActionStep step((__bridge CFDictionaryRef)stepDescription);
	HandleActionStep(step, context,
		^(dispatch_block_t action,
		__unused NSArray<NSString*> *inputs,
		__unused NSArray<NSString*> *mutatingInputs,
		__unused NSArray<NSString*> *exclusiveInputs,
		__unused NSArray<NSString*> *outputs)
		{
			if (action != NULL)
				AsyncDispatch(action);
		});
}
