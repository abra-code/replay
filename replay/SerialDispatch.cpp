#include "SerialDispatch.h"
#include <memory>

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
	dispatch_sync_f(context->queue, nullptr, [](void*){});
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
			[context](std::function<bool()> action,
			__unused std::vector<std::string> inputs,
			__unused std::vector<std::string> mutatingInputs,
			__unused std::vector<std::string> exclusiveInputs,
			__unused std::vector<std::string> outputs,
			__unused ActionCacheInfo cacheInfo)
			{
				if(action)
				{
					auto* fn = new std::function<bool()>(std::move(action));
					dispatch_async_f(context->queue, fn, [](void* ctx) {
						std::unique_ptr<std::function<bool()>> f{static_cast<std::function<bool()>*>(ctx)};
						(void)(*f)();
					});
				}
			});
	}

#if TRACE
	printf("done dispatching async tasks\n");
#endif

	FinishSerialDispatchAndWait(context);
}

void
DispatchTaskSerially(ActionStep step, ReplayContext *context)
{
	HandleActionStep(std::move(step), context,
		[context](std::function<bool()> action,
		__unused std::vector<std::string> inputs,
		__unused std::vector<std::string> mutatingInputs,
		__unused std::vector<std::string> exclusiveInputs,
		__unused std::vector<std::string> outputs,
		__unused ActionCacheInfo cacheInfo)
		{
			if(action)
			{
				auto* fn = new std::function<bool()>(std::move(action));
				dispatch_async_f(context->queue, fn, [](void* ctx) {
					std::unique_ptr<std::function<bool()>> f{static_cast<std::function<bool()>*>(ctx)};
					(void)(*f)();
				});
			}
		});
}
