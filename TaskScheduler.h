//
//  TaskScheduler.h
//
//  Created by Tomasz Kukielka on 9/5/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>

@class TaskProxy;

@interface TaskScheduler : NSObject

@property(nonatomic, readonly, strong) TaskProxy *rootTask;

- (instancetype) initWithConcurrencyLimit:(intptr_t)concurrencyLimit;
- (void)startExecutionAndWait;

@end //TaskScheduler
