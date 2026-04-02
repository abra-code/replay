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
						AsyncDispatch(action);
					}
				});
		}
		else
		{
			fprintf(gLogErr, "error: invalid non-dictionary step in the playlist\n");
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
				AsyncDispatch(action);
			}
		});
}

