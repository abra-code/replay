//
//  replay_server.h
//
//  Created by Tomasz Kukielka on 12/26/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#pragma once

#include <string>

#define REPLAY_GROUP_ID "group"

// The two ports of a batch (common/include/IpcPort.h): the server's, and the one
// dispatch's "wait" listens on for the server's exit.
inline std::string ReplayServerPortName(const std::string &batchName)
{
	return std::string(REPLAY_GROUP_ID ".replay-port.") + batchName;
}

inline std::string DispatchListenerPortName(const std::string &batchName)
{
	return std::string(REPLAY_GROUP_ID ".dispatch-port.") + batchName;
}

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
