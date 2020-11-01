//
//  TaskProxy.h
//
//  Created by Tomasz Kukielka on 9/20/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "MedusaTask.h"

//MedusaTask for concurrent execution with TaskScheduler

@interface TaskProxy : NSObject<MedusaTask>

@property(nonatomic) NSUInteger inputCount;
@property(nonatomic, unsafe_unretained) FileNode** inputs;

@property(nonatomic) NSUInteger outputCount;
@property(nonatomic, unsafe_unretained) FileNode** outputs;

- (id)initWithTask:(dispatch_block_t)task;
- (void)linkNextTask:(TaskProxy*)nextTask;

@end
