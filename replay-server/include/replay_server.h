//
//  replay_server.h
//
//  Created by Tomasz Kukielka on 12/26/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#include <CoreFoundation/CoreFoundation.h>

#define REPLAY_GROUP_ID "group"
#define GetAppGroupIdentifier() CFSTR(REPLAY_GROUP_ID)

static CFStringRef kReplayServerPortFormat = CFSTR("%@.replay-port.%@");
static CFStringRef kDispatchListenerPortFormat = CFSTR("%@.dispatch-port.%@");

enum ReplayMessage
{
	kReplayMessageStartServer = 1,
	kReplayMessageQueueActionDictionary,
	kReplayMessageQueueActionLine,
	kReplayMessageFinishAndWaitForAllActions
};

enum CallbackMessage
{
	kCallbackMessageHeartbeat = 1,
	kCallbackMessageExiting
};
