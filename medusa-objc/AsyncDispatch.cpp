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

#if defined(__linux__)
// Linux libdispatch has no kernel workqueue to replace a worker that blocks. A queue made
// with dispatch_queue_create(CONCURRENT) feeds a pool of one thread per CPU, and past that
// a timer adds one thread per second while every worker is blocked (src/queue.c and
// src/event/workqueue.c in swift-corelibs-libdispatch). Actions mostly block - an execute
// waits for its child process - so 200 of them sleeping 5 s took 45 s instead of 5 s.
// A serial queue feeds the overcommit pool instead, which starts a thread for each item
// as it arrives, so every task gets its own serial queue. Without a cap that pool goes to
// 255 threads, each holding a child process and its pipes; macOS gives this kind of queue
// at most 64 threads, so Linux applies the same number when no limit is given.
static const intptr_t kLinuxDefaultConcurrencyLimit = 64;

static void dispatch_on_own_queue(dispatch_group_t group, void *context, dispatch_function_t function)
{
    dispatch_queue_t queue = dispatch_queue_create("concurrent.playback.task", DISPATCH_QUEUE_SERIAL);
    dispatch_group_async_f(group, queue, context, function);
    dispatch_release(queue); // the queue keeps itself alive until the item has run
}
#endif

void StartAsyncDispatch(intptr_t councurrencyLimit)
{
    static intptr_t sLimit = 0;
    static dispatch_once_t sOnceToken;
    sLimit = councurrencyLimit;
#if defined(__linux__)
    if(sLimit <= 0)
        sLimit = kLinuxDefaultConcurrencyLimit;
#endif
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
            dispatch_function_t run = [](void* ctx2) {
                std::unique_ptr<std::function<void()>> f{static_cast<std::function<void()>*>(ctx2)};
                (*f)();
                dispatch_semaphore_signal(sConcurrencyLimitSemaphore);
            };
#if defined(__linux__)
            dispatch_on_own_queue(sGroup, inner, run);
#else
            dispatch_group_async_f(sGroup, sConcurrentQueue, inner, run);
#endif
        });
    }
}

void FinishAsyncDispatchAndWait(void)
{
    dispatch_group_wait(sGroup, DISPATCH_TIME_FOREVER);
}
