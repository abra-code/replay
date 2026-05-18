//
//  ReplayServer.cpp
//
//  Created by Tomasz Kukielka on 12/26/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import "replay_server.h"
#include "ReplayServer.h"
#include "ConcurrentDispatchWithNoDependency.h"
#include "SerialDispatch.h"
#include "ActionStream.h"
#include "CFObj.h"
#include "CFType.h"

CFMessagePortRef
CreateCallbackPort(const std::string &batchName)
{
	CFObj<CFStringRef> batchStr(CFStringCreateWithCString(kCFAllocatorDefault, batchName.c_str(), kCFStringEncodingUTF8));
	CFObj<CFStringRef> portName(CFStringCreateWithFormat(kCFAllocatorDefault, NULL, kDispatchListenerPortFormat, CFSTR(REPLAY_GROUP_ID), (CFStringRef)batchStr));
	if(portName == NULL)
	{
		LogError("error: could not create port name %s\n", batchName.c_str());
		return NULL;
	}
	return CFMessagePortCreateRemote(kCFAllocatorDefault, portName);
}

void
SendCallbackMessage(ReplayContext *context, SInt32 messageID)
{
	if(context->callbackPort == NULL)
		return;

	if(messageID != kCallbackMessageHeartbeat && messageID != kCallbackMessageExiting)
		return;

	CFObj<CFMutableDictionaryRef> callbackInfo(CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));

	if(context->lastError.hasError())
	{
		CFObj<CFStringRef> errStr(CFStringCreateWithCString(kCFAllocatorDefault, context->lastError.description().c_str(), kCFStringEncodingUTF8));
		CFDictionarySetValue(callbackInfo, CFSTR("lastError"), errStr);
	}

	CFObj<CFDataRef> plistData(CFPropertyListCreateData(kCFAllocatorDefault, callbackInfo, kCFPropertyListBinaryFormat_v1_0, 0, NULL));
	if(plistData != NULL)
	{
		/*int result =*/ CFMessagePortSendRequest(context->callbackPort, messageID, plistData, 5/*send timeout*/, 0/*rcv timeout*/, NULL, NULL);
	}
}

static inline ActionStep
ActionDictionaryFromData(ReplayContext *context, CFDataRef inData)
{
	CFDictionaryRef replayMessage = NULL;
	if((inData != NULL) && (CFDataGetLength(inData) > 0))
	{//CFData containing property list dictionary
		CFErrorRef error = NULL;
		CFPropertyListRef rawMessage = CFPropertyListCreateWithData(kCFAllocatorDefault, inData, kCFPropertyListImmutable, NULL, &error);
		if(rawMessage == NULL)
		{
			if(error != NULL)
				CFRelease(error);
			LogError("error: corrupt mesage - cannot unpack property list dictionary from data\n");
			if(context->stopOnError)
				context->lastError.set("error: corrupt message - cannot unpack property list dictionary from data", 1);
		}
		else
		{
			replayMessage = CFType<CFDictionaryRef>::DynamicCast(rawMessage);
			if(replayMessage == NULL)
			{
				CFRelease(rawMessage);
				LogError("error: invalid message - cannot unpack property list dictionary from data\n");
				if(context->stopOnError)
					context->lastError.set("error: invalid message - cannot unpack property list dictionary from data", 1);
			}
		}
	}
	// ActionStep ctor retains; replayMessage raw pointer released by going out of scope
	// via the CFObj wrapper below -> net retain = 1 in ActionStep.
	CFObj<CFDictionaryRef> owned(replayMessage);
	return ActionStep((CFDictionaryRef)owned);
}


static CFDataRef
ReplayListenerProc(CFMessagePortRef inLocalPort, SInt32 inMessageID, CFDataRef inData, void *info)
{
#pragma unused(inLocalPort)

	ReplayContext *context = (ReplayContext *)info;
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
			context->callbackPort = CreateCallbackPort(context->batchName);
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
	CFObj<CFMutableDictionaryRef> replayReply(CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
	CFObj<CFNumberRef> pidNum(CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &myPid));
	CFDictionarySetValue(replayReply, CFSTR("pid"), pidNum);

	if(context->lastError.hasError())
	{
		CFObj<CFStringRef> errStr(CFStringCreateWithCString(kCFAllocatorDefault, context->lastError.description().c_str(), kCFStringEncodingUTF8));
		CFDictionarySetValue(replayReply, CFSTR("lastError"), errStr);
	}

	return CFPropertyListCreateData(kCFAllocatorDefault, replayReply, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
}


void
StartServerAndRunLoop(ReplayContext *context)
{
	CFObj<CFMessagePortRef> localPort;
	assert(!context->batchName.empty());
	CFObj<CFStringRef> batchStr(CFStringCreateWithCString(kCFAllocatorDefault, context->batchName.c_str(), kCFStringEncodingUTF8));
	CFObj<CFStringRef> portName(CFStringCreateWithFormat(kCFAllocatorDefault, NULL, kReplayServerPortFormat, CFSTR(REPLAY_GROUP_ID), (CFStringRef)batchStr));
	if(portName == NULL)
	{
		LogError("error: could not create port name %s\n", context->batchName.c_str());
		safe_exit(EXIT_FAILURE);
	}

	CFMessagePortContext messagePortContext = { 0, (void *)context, NULL, NULL, NULL };
	localPort.Adopt(CFMessagePortCreateLocal(kCFAllocatorDefault, portName, ReplayListenerProc, &messagePortContext, NULL));
	if(localPort == NULL)
	{
		LogError("error: could not create a local message port\n");
		safe_exit(EXIT_FAILURE);
	}

	CFObj<CFRunLoopSourceRef> runLoopSource(CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, localPort, 0));
	if(runLoopSource == NULL)
	{
		LogError("error: could not create a runloop source\n");
		safe_exit(EXIT_FAILURE);
	}

	CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);

	StartReceivingActions(context);

	CFRunLoopRun(); //the runloop will be stopped when we receive kReplayMessageFinishAndWaitForAllActions from "dispatch"

	CFMessagePortInvalidate(localPort);
	CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);

	FinishReceivingActionsAndWait(context);

	//notify "dispatch" that "replay" server is exiting
	SendCallbackMessage(context, kCallbackMessageExiting);
}
