//
//  MedusaTaskProxy.m
//
//  Created by Tomasz Kukielka on 9/20/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "MedusaTaskProxy.h"

//#define TRACE_PROXY 1

@interface MedusaTaskProxy()
	@property(nonatomic, strong) dispatch_block_t taskBlock;
	@property(nonatomic) bool executed;
@end

@implementation MedusaTaskProxy

- (id)initWithTask:(dispatch_block_t)task
{
	self = [super init];
	if(self != nil)
	{
		_taskBlock = task;
		_executed = false;
	}

	return self;
}


- (void)executeTask
{
#if TRACE_PROXY
	printf("executing proxy = %p\n", (__bridge void *)self);
#endif
	
	// there must be no mistake in algorithm
	// no matter what, the task in graph can only be executed once
	assert(!_executed);
	
	@autoreleasepool
	{
		//execute the actual requested task now
		_taskBlock();
		
		_executed = true;
		
		// free some memory
		// in single-threaded recurive algorithm it does not have a big perf penalty
		_taskBlock = NULL;
	}
}

#if TRACE_PROXY
-(void)dealloc
{
	 printf("dealloc proxy = %p\n", (__bridge void *)self);
}
#endif

@end //@implementation MedusaTaskProxy

