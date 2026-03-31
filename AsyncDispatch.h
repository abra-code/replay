//
//  AsyncDispatch.h
//
//  Created by Tomasz Kukielka on 1/17/21.
//  Copyright © 2021 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void StartAsyncDispatch(intptr_t councurrencyLimit);
void AsyncDispatch(dispatch_block_t block);
void FinishAsyncDispatchAndWait(void);

#ifdef __cplusplus
}
#endif
