//
//  ReplayServer.cpp
//
//  Created by Tomasz Kukielka on 12/26/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#include "replay_server.h"
#include "ReplayServer.h"
#include "ConcurrentDispatchWithNoDependency.h"
#include "SerialDispatch.h"
#include "ActionStream.h"
#include "CFObj.h"
#include "CFType.h"
#include "CFStr.h"
#include "CFDict.h"

void
SendCallbackMessage(ReplayContext *context, SInt32 messageID)
{
	if (context->callbackPort == nullptr)
		return;

	if ((messageID != kCallbackMessageHeartbeat) && (messageID != kCallbackMessageExiting))
		return;

	CFMutableDict callbackInfo;

	if (context->lastError.hasError())
		callbackInfo.SetValue(CFSTR("lastError"), CFStr(context->lastError.description()));

	CFObj<CFDataRef> plistData(CFPropertyListCreateData(kCFAllocatorDefault, callbackInfo, kCFPropertyListBinaryFormat_v1_0, 0, nullptr));
	if (plistData != nullptr)
	{
		/*int result =*/ context->callbackPort->SendRequest(messageID, plistData, 5/*send timeout*/, 0/*rcv timeout*/, nullptr);
	}
}

static inline ActionStep
ActionDictionaryFromData(ReplayContext *context, CFDataRef inData)
{
	CFObj<CFPropertyListRef> rawMessage;
	CFDictionaryRef replayMessage = NULL; // borrowed from rawMessage
	if((inData != NULL) && (CFDataGetLength(inData) > 0))
	{//CFData containing property list dictionary
		CFObj<CFErrorRef> error;
		rawMessage.Adopt(CFPropertyListCreateWithData(kCFAllocatorDefault, inData, kCFPropertyListImmutable, NULL, &error));
		if(rawMessage == nullptr)
		{
			LogError("error: corrupt message - cannot unpack property list dictionary from data\n");
			if(context->stopOnError)
				context->lastError.set("error: corrupt message - cannot unpack property list dictionary from data", 1);
		}
		else
		{
			replayMessage = CFType<CFDictionaryRef>::DynamicCast(rawMessage);
			if(replayMessage == NULL)
			{
				LogError("error: invalid message - cannot unpack property list dictionary from data\n");
				if(context->stopOnError)
					context->lastError.set("error: invalid message - cannot unpack property list dictionary from data", 1);
			}
		}
	}
	// ActionStep retains the dictionary; rawMessage releases this function's reference.
	return ActionStep(replayMessage);
}


static CFObj<CFDataRef>
ReplayListenerProc(ReplayContext *context, int32_t inMessageID, CFDataRef inData)
{
	bool stopLoop = false;
	ActionStep actionDescription;

	switch(inMessageID)
	{
		case kReplayMessageStartServer:
			//do nothing, just acknowledge the readiness with reply
		break;

		case kReplayMessageQueueActionDictionary:
		{
			actionDescription = ActionDictionaryFromData(context, inData);
		}
		break;

		case kReplayMessageQueueActionLine:
		{
			if(inData != NULL)
			{
				CFIndex lineLen = CFDataGetLength(inData);
				const UInt8 *descriptionLinePtr = CFDataGetBytePtr(inData);
				actionDescription = ActionDescriptionFromLine((const char *)descriptionLinePtr, lineLen);
			}
		}
		break;

		case kReplayMessageFinishAndWaitForAllActions:
		{
			assert(!context->batchName.empty());
			context->callbackPort = ipc::Port::CreateRemote(DispatchListenerPortName(context->batchName));
			stopLoop = true;
		}
		break;

		default:
		{
			LogError("error: unknown action request received\n");
			if(context->stopOnError)
			{
				context->lastError.set("error: unknown message request received", 1);
				stopLoop = true;
			}
		}
		break;
	}

	if((inMessageID == kReplayMessageQueueActionDictionary) || (inMessageID == kReplayMessageQueueActionLine))
	{
		if(!actionDescription.empty())
		{
			if(context->concurrent)
				DispatchTaskConcurrentlyWithNoDependency(std::move(actionDescription), context);
			else
				DispatchTaskSerially(std::move(actionDescription), context);
		}
		else
		{
			LogError("error: invalid null action request received\n");
			if(context->stopOnError)
			{
				context->lastError.set("error: invalid null action request received", 1);
				stopLoop = true;
			}
		}
	}

	if(stopLoop)
	{
		CFRunLoopStop(CFRunLoopGetCurrent());
	}

	pid_t myPid = getpid();
	CFMutableDict replayReply;
	replayReply.SetValue(CFSTR("pid"), (int64_t)myPid);

	if (context->lastError.hasError())
		replayReply.SetValue(CFSTR("lastError"), CFStr(context->lastError.description()));

	return CFObj<CFDataRef>(CFPropertyListCreateData(kCFAllocatorDefault, replayReply, kCFPropertyListBinaryFormat_v1_0, 0, nullptr));
}


void
StartServerAndRunLoop(ReplayContext *context)
{
	assert(!context->batchName.empty());
	std::unique_ptr<ipc::Port> localPort = ipc::Port::CreateLocal(ReplayServerPortName(context->batchName),
		[context](int32_t messageId, CFDataRef data) { return ReplayListenerProc(context, messageId, data); });
	if(localPort == nullptr)
	{
		LogError("error: could not create a local message port\n");
		safe_exit(EXIT_FAILURE);
	}

	if(!localPort->AddToCurrentRunLoop())
	{
		LogError("error: could not create a runloop source\n");
		safe_exit(EXIT_FAILURE);
	}

	StartReceivingActions(context);

	CFRunLoopRun(); //the runloop will be stopped when we receive kReplayMessageFinishAndWaitForAllActions from "dispatch"

	localPort->Invalidate();

	FinishReceivingActionsAndWait(context);

	//notify "dispatch" that "replay" server is exiting
	SendCallbackMessage(context, kCallbackMessageExiting);
}
