//
//  AsyncDispatch.h
//
//  Created by Tomasz Kukielka on 1/17/21.
//  Copyright © 2021 Tomasz Kukielka. All rights reserved.
//

#include <dispatch/dispatch.h>
#include <functional>

void StartAsyncDispatch(intptr_t councurrencyLimit);
void AsyncDispatch(std::function<void()> work);
void FinishAsyncDispatchAndWait(void);
