//
//  AsyncDispatch.cpp
//
//  Created by Tomasz Kukielka on 1/17/21.
//  Copyright © 2021 Tomasz Kukielka. All rights reserved.
//

#include "AsyncDispatch.h"
#include <assert.h>
#include <memory>

static dispatch_queue_t sConcurrentQueue = nullptr;
static dispatch_group_t sGroup = nullptr;
static dispatch_semaphore_t sConcurrencyLimitSemaphore = nullptr;
static dispatch_queue_t sSerialLimitQueue = nullptr;

void StartAsyncDispatch(intptr_t councurrencyLimit)
{
    static intptr_t sLimit = 0;
    static dispatch_once_t sOnceToken;
    sLimit = councurrencyLimit;
    dispatch_once_f(&sOnceToken, nullptr, [](void*) {
        sConcurrentQueue = dispatch_queue_create("concurrent.playback", DISPATCH_QUEUE_CONCURRENT);
        sGroup = dispatch_group_create();
        if(sLimit > 0)
        {
            sConcurrencyLimitSemaphore = dispatch_semaphore_create(sLimit);
            sSerialLimitQueue = dispatch_queue_create("serial.limit", DISPATCH_QUEUE_SERIAL);
        }
    });
}

void AsyncDispatch(std::function<void()> work)
{
    if(sSerialLimitQueue == nullptr)
    {
        auto* fn = new std::function<void()>(std::move(work));
        dispatch_group_async_f(sGroup, sConcurrentQueue, fn, [](void* ctx) {
            std::unique_ptr<std::function<void()>> f{static_cast<std::function<void()>*>(ctx)};
            (*f)();
        });
    }
    else
    {
        auto* fn = new std::function<void()>(std::move(work));
        dispatch_group_async_f(sGroup, sSerialLimitQueue, fn, [](void* ctx) {
            std::unique_ptr<std::function<void()>> outer{static_cast<std::function<void()>*>(ctx)};
            assert(sConcurrencyLimitSemaphore != nullptr);
            dispatch_semaphore_wait(sConcurrencyLimitSemaphore, DISPATCH_TIME_FOREVER);
            auto* inner = new std::function<void()>(std::move(*outer));
            dispatch_group_async_f(sGroup, sConcurrentQueue, inner, [](void* ctx2) {
                std::unique_ptr<std::function<void()>> f{static_cast<std::function<void()>*>(ctx2)};
                (*f)();
                dispatch_semaphore_signal(sConcurrencyLimitSemaphore);
            });
        });
    }
}

void FinishAsyncDispatchAndWait(void)
{
    dispatch_group_wait(sGroup, DISPATCH_TIME_FOREVER);
}
