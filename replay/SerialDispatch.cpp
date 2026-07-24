#include "SerialDispatch.h"
#include "TaskCache.h"
#include "LogStream.h"
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

	// Same cache lifecycle as the dependency-analysis engine, same wrapper, same
	// manifest. Streaming and server modes route through DispatchTaskSerially below
	// and never enable the cache (they have no playlist file to key a manifest on).
	// Declared before the loop so the queued task blocks, which capture record
	// pointers, are all drained before the session is destroyed.
	std::unique_ptr<CacheSession> cacheSession;
	if(context->cacheEnabled && !context->playlistPath.empty())
	{
		cacheSession = std::make_unique<CacheSession>(context->playlistPath, context->playlistKey, context);
		cacheSession->load();
		context->cacheSession = cacheSession.get();
		if(context->verbose)
		{
			LogError("cache: loaded %zu entries from %s\n",
				cacheSession->loaded_entry_count(), cacheSession->manifest_path().c_str());
		}
	}

#if TRACE
	printf("start dispatching async tasks\n");
#endif

	for (const auto& step : playlist)
	{
		HandleActionStep(step, context,
			[context, &step](std::function<bool()> action,
			std::vector<std::string> inputs,
			std::vector<std::string> mutatingInputs,
			std::vector<std::string> exclusiveInputs,
			std::vector<std::string> outputs,
			ActionCacheInfo cacheInfo)
			{
				if(action)
				{
					std::string actionName = step.string_value("action").value_or(std::string());
					std::function<void()> wrapped = WrapActionWithCache(std::move(action), actionName,
						inputs, mutatingInputs, exclusiveInputs, outputs, cacheInfo, context);
					auto* fn = new std::function<void()>(std::move(wrapped));
					dispatch_async_f(context->queue, fn, [](void* ctx) {
						std::unique_ptr<std::function<void()>> f{static_cast<std::function<void()>*>(ctx)};
						(*f)();
					});
				}
			});
	}

#if TRACE
	printf("done dispatching async tasks\n");
#endif

	FinishSerialDispatchAndWait(context);

	if(cacheSession != nullptr)
	{
		// HandleActionStep returns without looking at later steps once an error is set
		// under --stop-on-error, so their entries must not be mistaken for removed steps.
		bool buildComplete = !(context->stopOnError && context->lastError.hasError());
		cacheSession->set_prune_allowed(buildComplete);

		// Never write a manifest under --dry-run - nothing actually happened.
		if(!context->dryRun)
		{
			cacheSession->finalize_and_save();
		}
	}
	context->cacheSession = nullptr;
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
