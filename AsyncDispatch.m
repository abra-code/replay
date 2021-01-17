//
//  TaskScheduler.m
//
//  Created by Tomasz Kukielka on 1/17/21.
//  Copyright © 2021 Tomasz Kukielka. All rights reserved.
//

#import "AsyncDispatch.h"

dispatch_queue_t sQueue = nil;
dispatch_group_t sGroup = nil;

void StartAsyncDispatch(void)
{
    static dispatch_once_t sOnceToken;
    dispatch_once(&sOnceToken, ^{
		sQueue = dispatch_queue_create("concurrent.playback", DISPATCH_QUEUE_CONCURRENT);
		sGroup = dispatch_group_create();
    });
}

void AsyncDispatch(dispatch_block_t block)
{
	dispatch_group_async(sGroup, sQueue, block);
}

void FinishAsyncDispatchAndWait(void)
{
	dispatch_group_wait(sGroup, DISPATCH_TIME_FOREVER);
}

