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
DispatchTasksSerially(NSArray<NSDictionary*> *playlist, ReplayContext *context)
{
	StartSerialDispatch(context);

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
						// with serial queue the tasks still execute one after another, never overlapping
						// dispatch_async allows us to keep iterating, building and adding new tasks
						// while the ones dispatched are already executing on the background thread
						dispatch_async(context->queue, action);
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

	FinishSerialDispatchAndWait(context);
}

void
DispatchTaskSerially(NSDictionary *stepDescription, ReplayContext *context)
{
	HandleActionStep(stepDescription, context,
		^(dispatch_block_t action,
		__unused NSArray<NSString*> *inputs,
		__unused NSArray<NSString*> *exclusiveInputs,
		__unused NSArray<NSString*> *outputs)
		{
			if(action != NULL)
			{
				// with serial queue the tasks still execute one after another, never overlapping
				// dispatch_async allows us to keep iterating, building and adding new tasks
				// while the ones dispatched are already executing on the background thread
				dispatch_async(context->queue, action);
			}
		});
}
