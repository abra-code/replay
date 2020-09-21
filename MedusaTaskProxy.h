//
//  MedusaTaskProxy.h
//
//  Created by Tomasz Kukielka on 9/20/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "MedusaTask.h"

//MedusaTask for recursive single-threaded execution
@interface MedusaTaskProxy : NSObject<MedusaTask>

@property(nonatomic, strong) NSMutableArray<PathSpec*> *inputs;
@property(nonatomic, strong) NSMutableArray<PathSpec*> *outputs;

- (id)initWithTask:(dispatch_block_t)task;
- (void)executeTask;

@end
