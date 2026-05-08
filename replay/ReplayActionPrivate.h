#pragma once
// Shared inline output helpers for action implementation files.
// Include only in action .mm files — not in public headers.

#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "OutputSerializer.h"
#include <cassert>

static inline void PrintToStdOut(ReplayContext *context, NSString *string, NSInteger actionIndex)
{
	if(context->orderedOutput)
	{
		assert(context->outputSerializer != nil);
		assert(actionIndex >= 0);
	}
	PrintSerializedString(context->outputSerializer, string, context->orderedOutput ? actionIndex : -1);
}

static inline void PrintToStdErr(ReplayContext *context, NSString *string)
{
	PrintSerializedErrorString(context->outputSerializer, string);
}

static inline void PrintStringsToStdOut(ReplayContext *context, NSArray<NSString *> *array, NSInteger actionIndex)
{
	if(context->orderedOutput)
	{
		assert(context->outputSerializer != nil);
		assert(actionIndex >= 0);
	}
	PrintSerializedStrings(context->outputSerializer, array, context->orderedOutput ? actionIndex : -1);
}

static inline void ActionWithNoOutput(ReplayContext *context, NSInteger actionIndex)
{
	if(context->orderedOutput)
	{
		assert(context->outputSerializer != nil);
		assert(actionIndex >= 0);
		PrintSerializedString(context->outputSerializer, nil, actionIndex);
	}
}
