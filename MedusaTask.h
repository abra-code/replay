//
//  MedusaTask.h
//
//  Created by Tomasz Kukielka on 9/20/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>

//#define ENABLE_DEBUG_DUMP 1

#import "FileTree.h"

@protocol MedusaTask

@required

@property(nonatomic) NSUInteger inputCount;
@property(nonatomic, unsafe_unretained) FileNode** inputs;

@property(nonatomic) NSUInteger outputCount;
@property(nonatomic, unsafe_unretained) FileNode** outputs;

- (id)initWithTask:(dispatch_block_t)task;

@optional
//for concurrent scheduler but not for recursive executor
- (void)linkNextTask:(id<MedusaTask>)nextTask;
#if ENABLE_DEBUG_DUMP
- (void)dumpDescription;
#endif
@end //MedusaTask
