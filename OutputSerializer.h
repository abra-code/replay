//
//  OutputSerializer.h
//  replay
//
//  Created by Tomasz Kukielka on 11/25/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface OutputSerializer : NSObject

+ (nonnull instancetype)sharedOutputSerializer;

@end //OutputSerializer


void PrintSerializedString(OutputSerializer * _Nullable serializer, NSString * _Nullable string, NSInteger actionIndex);
void PrintSerializedStrings(OutputSerializer * _Nullable serializer, NSArray<NSString *> * _Nullable array, NSInteger actionIndex);
void FlushSerializedOutputs(OutputSerializer * _Nonnull serializer);