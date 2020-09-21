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

@property(nonatomic, strong) NSMutableArray<PathSpec*> *inputs;
@property(nonatomic, strong) NSMutableArray<PathSpec*> *outputs;

- (id)initWithTask:(dispatch_block_t)task;
- (void)linkNextTask:(TaskProxy*)nextTask;

@end
