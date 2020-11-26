#import "ConcurrentDispatchWithNoDependency.h"

void
StartConcurrentDispatchWithNoDependency(ReplayContext *context)
{
	assert(context->concurrent);
	assert(context->queue == NULL);
	context->queue = dispatch_queue_create("concurrent.playback", DISPATCH_QUEUE_CONCURRENT);
	assert(context->group == NULL);
	context->group = dispatch_group_create();
}

void
FinishConcurrentDispatchWithNoDependencyAndWait(ReplayContext *context)
{
	dispatch_group_wait(context->group, DISPATCH_TIME_FOREVER);
}

void
DispatchTasksConcurrentlyWithNoDependency(NSArray<NSDictionary*> *playlist, ReplayContext *context)
{
	StartConcurrentDispatchWithNoDependency(context);

#if TRACE
	printf("start dispatching async tasks\n");
#endif

	Class dictionaryClass = [NSDictionary class];

	for(id oneStep in playlist)
	{
		if([oneStep isKindOfClass:dictionaryClass])
		{
			HandleActionStep((NSDictionary *)oneStep, context,
				^(dispatch_block_t action,
				__unused NSArray<NSString*> *inputs,
				__unused NSArray<NSString*> *exclusiveInputs,
				__unused NSArray<NSString*> *outputs)
				{
					if(action != NULL)
					{
						dispatch_group_async(context->group, context->queue, action);
					}
				});
		}
		else
		{
			fprintf(stderr, "error: invalid non-dictionary step in the playlist\n");
		}
	}

#if TRACE
	printf("done dispatching async tasks\n");
#endif

	FinishConcurrentDispatchWithNoDependencyAndWait(context);
}

void
DispatchTaskConcurrentlyWithNoDependency(NSDictionary *stepDescription, ReplayContext *context)
{
	HandleActionStep(stepDescription, context,
		^(dispatch_block_t action,
		__unused NSArray<NSString*> *inputs,
		__unused NSArray<NSString*> *exclusiveInputs,
		__unused NSArray<NSString*> *outputs)
		{
			if(action != NULL)
			{
				dispatch_group_async(context->group, context->queue, action);
			}
		});
}

