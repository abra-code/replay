//
//  PathSpec.m
//
//  Created by Tomasz Kukielka on 9/20/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "PathSpec.h"

@implementation PathSpec

- (id)initWithPath:(NSString *)path
{
	self = [super init];
	if(self != nil)
	{
		_path = path;
	}
	return self;
}

@end //@implementation PathSpec
