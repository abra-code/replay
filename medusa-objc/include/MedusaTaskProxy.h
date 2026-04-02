//
//  MedusaTaskProxy.h
//
//  Created by Tomasz Kukielka on 9/20/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "MedusaTask.h"

#ifdef __cplusplus
extern "C" {
#endif

//MedusaTask for recursive single-threaded execution
@interface MedusaTaskProxy : NSObject<MedusaTask>

@property(nonatomic) bool executed;

@property(nonatomic) NSUInteger inputCount;
@property(nonatomic, unsafe_unretained) FileNode** inputs;

@property(nonatomic) NSUInteger outputCount;
@property(nonatomic, unsafe_unretained) FileNode** outputs;

- (id)initWithTask:(dispatch_block_t)task;
- (void)executeTask;

@end

#ifdef __cplusplus
}
#endif
