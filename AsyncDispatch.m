//
//  TaskScheduler.m
//
//  Created by Tomasz Kukielka on 1/17/21.
//  Copyright © 2021 Tomasz Kukielka. All rights reserved.
//

#import "AsyncDispatch.h"

dispatch_queue_t sConcurrentQueue = nil;
dispatch_group_t sGroup = nil;
dispatch_semaphore_t sConcurrencyLimitSemaphore = nil;
dispatch_queue_t sSerialLimitQueue = nil;

void StartAsyncDispatch(intptr_t councurrencyLimit)
{
    static dispatch_once_t sOnceToken;
    dispatch_once(&sOnceToken, ^{
		sConcurrentQueue = dispatch_queue_create("concurrent.playback", DISPATCH_QUEUE_CONCURRENT);
		sGroup = dispatch_group_create();
		if(councurrencyLimit > 0) //0 = unlimited
		{
			sConcurrencyLimitSemaphore = dispatch_semaphore_create(councurrencyLimit);
			sSerialLimitQueue = dispatch_queue_create("serial.limit", DISPATCH_QUEUE_SERIAL);
		}
    });
}

void AsyncDispatch(dispatch_block_t block)
{
	if(sSerialLimitQueue == nil)
	{// no limit
		dispatch_group_async(sGroup, sConcurrentQueue, block);
	}
	else
	{
		dispatch_group_async(sGroup, sSerialLimitQueue, ^{
			assert(sConcurrencyLimitSemaphore != nil);
			// if we are below the limit, dispatch_semaphore_wait quickly returns
			// otherwise we wait for other tasks to finish and call dispatch_semaphore_signal
			dispatch_semaphore_wait(sConcurrencyLimitSemaphore, DISPATCH_TIME_FOREVER);
			dispatch_group_async(sGroup, sConcurrentQueue, ^{
				block();
				dispatch_semaphore_signal(sConcurrencyLimitSemaphore);
			});
		});
	}
}

void FinishAsyncDispatchAndWait(void)
{
	dispatch_group_wait(sGroup, DISPATCH_TIME_FOREVER);
}

