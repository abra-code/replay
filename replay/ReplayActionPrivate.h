#pragma once
// Shared inline output helpers for action implementation files.
// Include only in action .mm files — not in public headers.

#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#include "OutputSerializer.h"
#include <cassert>
#include <string>

static inline void PrintToStdOut(ReplayContext *context, std::string str, NSInteger actionIndex)
{
    assert(context->outputSerializer != nullptr);
    context->outputSerializer->scheduleString(
        std::move(str),
        context->orderedOutput ? (int64_t)actionIndex : -1
    );
}

static inline void PrintToStdErr(ReplayContext *context, std::string str)
{
    assert(context->outputSerializer != nullptr);
    context->outputSerializer->scheduleErrorString(std::move(str));
}

static inline void ActionWithNoOutput(ReplayContext *context, NSInteger actionIndex)
{
    if(context->orderedOutput)
    {
        assert(context->outputSerializer != nullptr);
        assert(actionIndex >= 0);
        context->outputSerializer->scheduleNoOutput((int64_t)actionIndex);
    }
}
