//
//  ReplayServer.m
//
//  Created by Tomasz Kukielka on 12/26/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import "ReplayServer.h"
#import "ConcurrentDispatchWithNoDependency.h"
#import "SerialDispatch.h"
#import "ActionStream.h"
#include "CFObj.h"
#include "CFType.h"

CFMessagePortRef
CreateCallbackPort(NSString *batchName)
{
	CFMessagePortRef remotePort = NULL;
	CFStringRef portName = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, kDispatchListenerPortFormat, GetAppGroupIdentifier(), batchName);
	if(portName == NULL)
	{
		LogError("error: could not create port name %s\n", ((__bridge NSString *)portName).UTF8String);
		return remotePort;
	}
	remotePort = CFMessagePortCreateRemote(kCFAllocatorDefault, portName);//should return non-null if listener port created
	return remotePort;
}

void
SendCallbackMessage(ReplayContext *context, SInt32 messageID)
{
	if(context->callbackPort == NULL)
		return;

	NSMutableDictionary *callbackInfo = [NSMutableDictionary new];
	
	if(context->lastError.hasError())
		callbackInfo[@"lastError"] = @(context->lastError.description().c_str());

	if(messageID == kCallbackMessageHeartbeat)
	{
		
	}
	else if(messageID == kCallbackMessageExiting)
	{
		
	}
	else
	{
		return;
	}

	CFObj<CFDataRef> plistData(CFPropertyListCreateData(kCFAllocatorDefault, (__bridge CFDictionaryRef)callbackInfo, kCFPropertyListBinaryFormat_v1_0, 0, NULL));
	if(plistData != NULL)
	{
		/*int result =*/ CFMessagePortSendRequest(context->callbackPort, messageID, plistData, 5/*send timeout*/, 0/*rcv timout*/, NULL, NULL);
	}
}

static inline NSDictionary *
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
			{
				context->lastError.set("error: corrupt message - cannot unpack property list dictionary from data", 1);
			}
		}
		else
		{
			replayMessage = CFType<CFDictionaryRef>::DynamicCast(rawMessage);
			if(replayMessage == NULL)
			{
				CFRelease(rawMessage);
				LogError("error: invalid message - cannot unpack property list dictionary from data\n");
				if(context->stopOnError)
				{
					context->lastError.set("error: invalid message - cannot unpack property list dictionary from data", 1);
				}
			}
		}
	}
	NSDictionary *actionDescription = CFBridgingRelease(replayMessage);
	return actionDescription;
}


static CFDataRef
ReplayListenerProc(CFMessagePortRef inLocalPort, SInt32 inMessageID, CFDataRef inData, void *info)
{
#pragma unused(inLocalPort)

	ReplayContext *context = (ReplayContext *)info;
	bool stopLoop = false;
	NSDictionary *actionDescription = nil;

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
			assert(context->batchName != nil);
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
		if(actionDescription != nil)
		{
			if(context->concurrent)
				DispatchTaskConcurrentlyWithNoDependency(actionDescription, context);
			else
				DispatchTaskSerially(actionDescription, context);
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

	NSMutableDictionary *replayReply = [NSMutableDictionary new];
	pid_t myPid = getpid();
	NSNumber *pidNum = @(myPid);
	replayReply[@"pid"] = pidNum;
	
	if(context->lastError.hasError())
		replayReply[@"lastError"] = @(context->lastError.description().c_str());
	
	CFDataRef plistData = CFPropertyListCreateData(kCFAllocatorDefault, (__bridge CFMutableDictionaryRef)replayReply, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
	return plistData;
}


void
StartServerAndRunLoop(ReplayContext *context)
{
	CFObj<CFMessagePortRef> localPort;
	assert(context->batchName != nil);
	CFObj<CFStringRef> portName(CFStringCreateWithFormat(kCFAllocatorDefault, NULL, kReplayServerPortFormat, GetAppGroupIdentifier(), context->batchName));
	if(portName == NULL)
	{
		LogError("error: could not create port name %s\n", ((__bridge NSString *)(CFStringRef)portName).UTF8String);
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

