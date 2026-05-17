#import "SerialDispatch.h"

void
StartSerialDispatch(ReplayContext *context)
{
	assert(!context->concurrent); //serial
	assert(context->queue == NULL);
	context->queue = dispatch_queue_create("serial.playback", DISPATCH_QUEUE_SERIAL);
}

void
FinishSerialDispatchAndWait(ReplayContext *context)
{
	dispatch_sync(context->queue, ^{
#if TRACE
			printf("executing terminating sync task\n");
#endif
		});
}

void
DispatchTasksSerially(const std::vector<ActionStep>& playlist, ReplayContext *context)
{
	StartSerialDispatch(context);

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
					dispatch_async(context->queue, action);
			});
	}

#if TRACE
	printf("done dispatching async tasks\n");
#endif

	FinishSerialDispatchAndWait(context);
}

void
DispatchTaskSerially(NSDictionary *stepDescription, ReplayContext *context)
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
				dispatch_async(context->queue, action);
		});
}
