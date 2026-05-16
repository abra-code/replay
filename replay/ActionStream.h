//
//  ActionStream.h
//
//  Created by Tomasz Kukielka on 12/26/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ReplayAction.h"

void StartReceivingActions(ReplayContext *context);
void FinishReceivingActionsAndWait(ReplayContext *context);
void StreamActionsFromStdIn(ReplayContext *context);
