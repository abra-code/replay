//
//  PathSpec.h
//
//  Created by Tomasz Kukielka on 9/20/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface PathSpec : NSObject

@property(nonatomic, strong) NSString *path;
@property(nonatomic) NSUInteger producerIndex;

- (id)initWithPath:(NSString *)path;

@end
