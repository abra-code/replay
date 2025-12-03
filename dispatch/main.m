//
//  main.m
//  dispatch
//
//  Created by Tomasz Kukielka on 12/23/20.
//

#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#import "ReplayServer.h"

#define STRINGIFY(x) #x
#define STRINGIFY_VALUE(x) STRINGIFY(x)

static inline BOOL
StartChildProcess(NSString *toolPath, NSArray<NSString*> *arguments)
{
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath:toolPath];
	[task setArguments:arguments];

	[task setTerminationHandler: ^(NSTask *task) {
		int toolStatus = [task terminationStatus];
		if(toolStatus != EXIT_SUCCESS)
		{
			fprintf(stderr, "error: failed to execute \"%s\". Error: %d\n", [toolPath UTF8String], toolStatus);
		}
	}];

/*
	NSPipe *stdOutPipe = [NSPipe pipe];
	[task setStandardOutput:stdOutPipe];
*/
	NSPipe *stdInPipe = [NSPipe pipe];
	[task setStandardInput:stdInPipe];

	NSError *operationError = nil;
	BOOL isSuccessful = [task launchAndReturnError:&operationError];
	
	if (!isSuccessful)
	{
		NSString *errorDesc = [operationError localizedDescription];
		if(errorDesc == nil)
		{
			errorDesc = [operationError localizedFailureReason];
		}
		fprintf(stderr, "error: failed to execute \"%s\". Error: %s\n", [toolPath UTF8String], [errorDesc UTF8String] );
	}
	
	return isSuccessful;
}


static CFDataRef
CallbackProc(CFMessagePortRef inLocalPort, SInt32 inMessageID, CFDataRef inData, void *info)
{
	if(inMessageID == kCallbackMessageHeartbeat)
	{
		//replay reports it is alive when we wait
		
	}
	else if(inMessageID == kCallbackMessageExiting)
	{
		CFMessagePortInvalidate(inLocalPort);
		CFRunLoopStop(CFRunLoopGetCurrent());
	}
	
	return NULL;
}


static CFRunLoopSourceRef
StartCallbackListener(NSString *batchName)
{
	CFMessagePortRef localPort = NULL;
	CFStringRef portName = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, kDispatchListenerPortFormat, GetAppGroupIdentifier(), batchName);
	if(portName == NULL)
	{
		fprintf(stderr, "error: could not create port name %s\n", ((__bridge NSString *)portName).UTF8String);
		exit(EXIT_FAILURE);
	}

	CFMessagePortContext messagePortContext = { 0, NULL, NULL, NULL, NULL };
	localPort = CFMessagePortCreateLocal(kCFAllocatorDefault, portName, CallbackProc, &messagePortContext, NULL);
	CFRelease(portName);
	if(localPort == NULL)
	{
		fprintf(stderr, "error: could not create a local message port\n");
		exit(EXIT_FAILURE);
	}
	
	CFRunLoopSourceRef runLoopSource = CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, localPort, 0);
	if(runLoopSource == NULL)
	{
		fprintf(stderr, "error: could not create a runloop source\n");
		exit(EXIT_FAILURE);
	}

	CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
	return runLoopSource;
}

static void
FinalizeCallbackListener(CFRunLoopSourceRef runLoopSource)
{
	if(runLoopSource != NULL)
	{
		CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
		CFRelease(runLoopSource);
	}
}

static void
StartProcessExitMonitoring(int pid)
{
    dispatch_source_t dispatch_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    if(dispatch_source != nil)
    { // dispatch_source is not null even if the process does not exist
      // but we immediately receive the event about its exit
      // so this code works well in case of race condition when the other process expired before we registered the monitoring
	    dispatch_source_set_event_handler(dispatch_source, ^{
			dispatch_source_cancel(dispatch_source);
			CFRunLoopStop(CFRunLoopGetCurrent());
	    });
		dispatch_resume(dispatch_source);
	}
}


CFMessagePortRef
StartReplayAndOpenRemotePort(NSString *pathToDispatch, CFStringRef portName, NSArray<NSString*> *arguments, bool ensureResponse)
{
	CFMessagePortRef remotePort = NULL;
// replay is expected to be in the same directory as dispatch
	NSURL *selfURL = [NSURL fileURLWithPath:pathToDispatch].absoluteURL;
	NSURL *parentURL = [selfURL URLByDeletingLastPathComponent];
	NSURL *replayURL = [parentURL URLByAppendingPathComponent:@"replay" isDirectory:NO];
	NSString *replayPath = replayURL.path;
	if(replayPath != nil)
	{
		BOOL replayStarted = StartChildProcess(replayPath, arguments);
		if(replayStarted)
		{
			for(int i = 0; i < 30; i++)
			{
				//retry opening the communication port with "replay"
				remotePort = CFMessagePortCreateRemote(kCFAllocatorDefault, portName);//should return non-null if listener port created
				if(remotePort != NULL)
					break;
				usleep(100000); //sleep 0.1 sec
			}
			
			if(remotePort == NULL)
			{
				fprintf(stderr, "error: could not communicate with \"replay\"\n");
			}
		}
		else
		{
			NSFileManager *fileManager = [NSFileManager defaultManager];
			if(![fileManager fileExistsAtPath:replayPath])
			{
				fprintf(stderr, "error: \"replay\" not found at %s\n", replayPath.UTF8String);
			}
		}
	}

	if((remotePort != NULL) && ensureResponse)
	{ //try sending a test message to see if we get a response
		for(int i = 0; i < 10; i++)
		{
			CFDataRef replayReplyData = NULL;
			int result = CFMessagePortSendRequest(remotePort, kReplayMessageStartServer, NULL, 10/*send timeout*/, 10/*rcv timout*/, kCFRunLoopDefaultMode, &replayReplyData);
			
			if(result == 0)
			{
				if(replayReplyData != NULL)
					CFRelease(replayReplyData);
				break;
			}
			usleep(100000); //sleep 0.1 sec
		}
	}
	
	return remotePort;
}


static int
SendActionsFromStdIn(CFMessagePortRef remotePort)
{
	int result = 0;
	char *line = NULL;
	size_t linecap = 0;
	ssize_t linelen;
	while ((linelen = getline(&line, &linecap, stdin)) > 0)
	{
		CFDataRef lineData = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)line, linelen);
		if(lineData != nil)
		{
			result = CFMessagePortSendRequest(remotePort, kReplayMessageQueueActionLine, lineData, 10/*send timeout*/, 0/*rcv timout*/, NULL, NULL);
			CFRelease(lineData);
			if(result != 0)
			{
				fprintf(stderr, "error: could not send dispatch request to \"replay\": %d\n", result);
				break;
			}
		}
		else
		{
			fprintf(stderr, "error: unable to allocate data buffer for line: %s\n", line);
			result = -1;
			break;
		}
	}

	//do not bother freeing the line buffer - the process is ending
	return result;
}

static void
DisplayHelp(void)
{
	printf(
		"\n"
		"\n"
		"dispatch -- companion tool for \"replay\" to simplify adding tasks for concurrent execution\n"
		"\n"
		"Usage:\n"
		"\n"
		"  dispatch batch-name [action-name] [action params]\n"
		"\n"
		"Description:\n"
		"\n"
		"  \"dispatch\" starts \"replay\" in server mode as a background process and sends tasks to it.\n"
		"Batch name is a required user-provided parameter to all invocations identifying a task batch.\n"
		"A batch can be understood as a single job with mutiple tasks. Each instance of \"replay\"\n"
		"running in a server mode is associated with one uniqueley named batch/job.\n"
		"\"dispatch\" is just a client-facing helper tool to send tasks to \"replay\" server.\n"
		"It is intended for ad hoc execution of unstructured tasks when the rate of scheduling tasks\n"
		"is higher than their execution time and they can be run concurrently.\n"
		"Invoking \"dispatch batch-name wait\" at the end allows the client script to wait for all\n"
		"scheduled tasks to finish.\n"
		"A typical sequence of calls could be demonstrated by the following example:\n"
		"\n"
		"   dispatch example-batch echo \"Starting the batch job\"\n"
		"   dispatch example-batch create file ${HOME}/she-sells.txt 'she sells'\n"
		"   dispatch example-batch execute /bin/sh -c \"/bin/echo 'sea shells' > ${HOME}/shells.txt\"\n"
		"   dispatch example-batch execute /bin/sleep 10\n"
		"   dispatch example-batch wait\n"
		"\n"
		"The first invocation of \"dispatch\" for unique batch name starts a new instance of \"replay\"\n"
		"server with default parameters. If you wish to control \"replay\" behavior you can start it\n"
		"explicitly with \"start\" action and provide parameters to forward to \"replay\", for example:\n"
		"\n"
		"   dispatch example-batch start --verbose --ordered-output --stop-on-error\n"
		"\n"
		"Subsequent use of \"start\" action for the same batch name will not restart the server\n"
		"but a warning will be printed about already running server instance.\n"
		"\n"
		"Supported actions are the same as \"replay\" actions plus a couple of special control words:\n"
		"\n"
		"   start [replay options]\n"
		"   clone /from/item/path /to/item/path\n"
		"   copy /from/item/path /to/item/path\n"
		"   move /from/item/path /to/item/path\n"
		"   hardlink /from/item/path /to/item/path\n"
		"   symlink /from/item/path /to/item/path\n"
		"   create file /path/to/new/file \"New File Content\"\n"
		"   create directory /path/to/new/dir\n"
		"   delete /path/to/item1 /path/to/item2 /path/to/itemN\n"
		"   execute /path/to/tool param1 param2 paramN\n"
		"   echo \"String to print\"\n"
		"   wait\n"
		"\n"
		"If invoked without any action name, \"dispatch\" opens a standard input for streaming actions\n"
		"in the same format as accepted by \"replay\" tool, for example:\n"
		"\n"
		"   echo \"[echo]|Streaming actions\" | dispatch stream-job\n"
		"   echo \"[execute]|/bin/ls|-la\" | dispatch stream-job\n"
		"   dispatch stream-job wait\n"
		"\n"
		"With a couple of notes:\n"
		" - you cannot pass \"start\" and \"wait\" options that way - these are instructions for\n"
		"   \"dispatch\" tool, not real actions to forward to \"replay\".\n"
		" - each line is sent to \"replay\" server separately so it is not as performant as streaming\n"
		"   actions directly to \"replay\" in regular, non-server mode.\n"
		" - \"replay\" stdout cannot be piped when executed this way but \"replay\" can be started\n"
		"   with --stdout /path/to/log.out and --stderr /path/to/log.err options keep the logs.\n"
		" - a reminder that streaming actions as text requires parameters to be separated by some\n"
		"   non-interfering field separator (vertical bar in the above example).\n"
		"\n"
		"\n"
		"Options:\n"
		"\n"
		"  -V, --version      Display version.\n"
		"  -h, --help         Display this help\n"
		"\n"
		"See also:\n"
		"\n"
		"  replay --help\n"
		"\n"
	);
}


//dispatch batch_name action_name <action params>

int main(int argc, const char * argv[])
{
	if(argc < 2)
	{
		DisplayHelp();
		return EXIT_FAILURE;
	}

	@autoreleasepool
	{
		int result = 0;
		NSString *pathToDispatchFromArg = @(argv[0]);
		NSString *batchName = @(argv[1]);
		NSString *actionName = nil;
		int lastArgIndex = argc-1;
		int currArgIndex = 2;

		if((argc == 2) && ([batchName isEqualToString:@"--help"] || [batchName isEqualToString:@"-h"]))
		{
			DisplayHelp();
			return EXIT_SUCCESS;
		}
		
		if((argc == 2) && ([batchName isEqualToString:@"--version"] || [batchName isEqualToString:@"-V"]))
		{
            printf( "dispatch %s\n", STRINGIFY_VALUE(REPLAY_VERSION) );
			return EXIT_SUCCESS;
		}

		CFStringRef portName = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, kReplayServerPortFormat, GetAppGroupIdentifier(), batchName);
		if(portName == NULL)
		{
			fprintf(stderr, "error: could not create port name %s\n", ((__bridge NSString *)portName).UTF8String);
			exit(EXIT_FAILURE);
		}

		bool isSrcDestAction = false;
		Action action = kActionInvalid;
		if(argc > 2)
		{
			actionName = @(argv[2]);
			action = ActionFromName(actionName,  &isSrcDestAction);
		}

		CFMessagePortRef remotePort = CFMessagePortCreateRemote(kCFAllocatorDefault, portName);//should return non-null if remote server port already created
		if(remotePort == NULL)
		{
			if(action != kActionWait)
			{
				NSMutableArray<NSString*> *arguments = [NSMutableArray new];
				[arguments addObject:@"--start-server"]; //this is mandatory arg
				[arguments addObject:batchName];
				
				if(action == kActionStartServer) //this is for explicit "start" action specified
				{// additional args are params for replay tools
					while(currArgIndex < lastArgIndex)
					{
						currArgIndex++;
						NSString *oneParam = @(argv[currArgIndex]);
						[arguments addObject:oneParam];
					}
				}
				
				// port not open, launch "replay" with batch name and specified params
				bool ensureResponse = (action != kActionStartServer); //when starting the server one message will be sent by default
				
				NSString *pathToDispatch = pathToDispatchFromArg; //fallback path
				char dispatchPath[PATH_MAX] = {0};
				uint32_t buffSize = PATH_MAX;
				int result = _NSGetExecutablePath(dispatchPath, &buffSize); //get real executable path
				if(result == 0)
				{
					pathToDispatch = @(dispatchPath);
				}
				remotePort = StartReplayAndOpenRemotePort(pathToDispatch, portName, arguments, ensureResponse);
			}
			else if(action == kActionWait)
			{
				fprintf(stderr, "warning: \"replay\" server not running for batch name \"%s\"\n", (batchName).UTF8String);
			}
		}
		else if(action == kActionStartServer)
		{
			fprintf(stderr, "warning: \"replay\" server already running for batch name \"%s\"\n", (batchName).UTF8String);
		}

		if(remotePort == NULL)
		{
			exit(EXIT_FAILURE);
		}
		
		if(argc == 2)
		{// this is the mode where only "dispatch batch_name" is used and the action description
		 // is read-in from stdin in the delimited format the same as "replay" uses
			result = SendActionsFromStdIn(remotePort);
			CFRelease(remotePort);
			exit((result == 0) ? EXIT_SUCCESS : EXIT_FAILURE);
		}

		CFRunLoopSourceRef callbackListenerRef = NULL;
		NSMutableDictionary *actionDescription = [NSMutableDictionary new];
		actionDescription[@"action"] = actionName;
		
		SInt32 msgid = kReplayMessageQueueActionDictionary;

		if(isSrcDestAction)
		{   // these require 2 arguments
			// kFileActionClone
			// kFileActionMove
			// kFileActionHardlink
			// kFileActionSymlink
			
			if(currArgIndex < lastArgIndex)
			{
				currArgIndex++;
				actionDescription[@"from"] = @(argv[currArgIndex]);
			}
			else
			{
				fprintf(stderr, "error: \"%s\" action requires exactly two paths\n", actionName.UTF8String);
				exit(EXIT_FAILURE);
			}
			
			if(currArgIndex < lastArgIndex)
			{
				currArgIndex++;
				actionDescription[@"to"] = @(argv[currArgIndex]);
			}
			else
			{
				fprintf(stderr, "error: \"%s\" action requires exactly two paths\n", actionName.UTF8String);
				exit(EXIT_FAILURE);
			}
		}
		else
		{
			switch(action)
			{
				case kActionStartServer:
				{
					msgid = kReplayMessageStartServer;
				}
				break;

				case kFileActionCreate:
				{
					NSString *type = nil;
					const char *typeStr = NULL;
					if(currArgIndex < lastArgIndex)
					{
						currArgIndex++;
						typeStr = argv[currArgIndex];
						type = @(typeStr);
					}
					else
					{
						fprintf(stderr, "error: \"create\" action requires \"file\" or \"directory\" specification and a path\n");
						exit(EXIT_FAILURE);
					}
					
					if((type != nil) && (currArgIndex < lastArgIndex))
					{
						currArgIndex++;
						NSString *path = @(argv[currArgIndex]);

						if([type isEqualToString:@"directory"])
						{
							actionDescription[@"directory"] = path;
						}
						else if([type isEqualToString:@"file"])
						{
							actionDescription[@"file"] = path;
							if(currArgIndex < lastArgIndex)
							{ //optional content
								currArgIndex++;
								actionDescription[@"content"] = @(argv[currArgIndex]);
							}
						}
						else
						{
							fprintf(stderr, "error: \"create\" action requires specifying \"file\" or \"directory\" but \"%s\" was given\n", typeStr);
							exit(EXIT_FAILURE);
						}
					}
				}
				break;
				
				case kFileActionDelete:
				{ // variable element input - all params are paths to delete
					if(currArgIndex < lastArgIndex)
					{
						NSMutableArray<NSString *> *paramArray = [NSMutableArray new];
						while(currArgIndex < lastArgIndex)
						{
							currArgIndex++;
							NSString *onePath = @(argv[currArgIndex]);
							[paramArray addObject:onePath];
						}
						actionDescription[@"items"] = paramArray;
					}
					else
					{
						fprintf(stderr, "error: \"delete\" action requires at least one path\n");
						exit(EXIT_FAILURE);
					}
				}
				break;
				
				case kActionExecuteTool:
				{
					if(currArgIndex < lastArgIndex)
					{
						currArgIndex++;
						actionDescription[@"tool"] = @(argv[currArgIndex]);
					}
					else
					{
						fprintf(stderr, "error: \"execute\" action requires a path to a tool\n");
						exit(EXIT_FAILURE);
					}
					
					if(currArgIndex < lastArgIndex)
					{
						NSMutableArray<NSString *> *args = [NSMutableArray new];
						while(currArgIndex < lastArgIndex)
						{
							currArgIndex++;
							NSString *onePath = @(argv[currArgIndex]);
							[args addObject:onePath];
						}
						actionDescription[@"arguments"] = args;
					}
				}
				break;
				
				case kActionEcho:
				{
					if(currArgIndex < lastArgIndex)
					{
						currArgIndex++;
						actionDescription[@"text"] = @(argv[currArgIndex]);
					}
					else
					{
						fprintf(stderr, "error: \"echo\" action requires a string parameter\n");
						exit(EXIT_FAILURE);
					}
				}
				break;
				
				case kActionWait:
				{
					// when we sit waiting, we expect callback messages from "replay"
					callbackListenerRef = StartCallbackListener(batchName);
					msgid = kReplayMessageFinishAndWaitForAllActions;
				}
				break;
				
				case kActionInvalid:
				default:
					fprintf(stderr, "error: invalid \"replay\" action: %s\n", actionName.UTF8String );
					exit(EXIT_FAILURE);
				break;
			}
		}

		CFDataRef plistData = CFPropertyListCreateData(kCFAllocatorDefault, (__bridge CFDictionaryRef)actionDescription, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
		CFDataRef replayReplyData = NULL;
		if(plistData != NULL)
		{
			result = CFMessagePortSendRequest(remotePort, msgid, plistData, 10/*send timeout*/, 10/*rcv timout*/, kCFRunLoopDefaultMode, &replayReplyData);
			CFRelease(plistData);
			if(result != 0)
			{
				fprintf(stderr, "error: could not send dispatch request to \"replay\": %d\n", result);
				exit(EXIT_FAILURE);
			}
		}

		int replayPID = 0;
		NSString *lastReplayError = nil;
		if(replayReplyData != NULL)
		{
			CFErrorRef error = NULL;
			NSDictionary *replayReply = CFBridgingRelease(CFPropertyListCreateWithData(kCFAllocatorDefault, replayReplyData, kCFPropertyListImmutable, NULL, &error));
			CFRelease(replayReplyData);
			if(replayReply != NULL)
			{
				lastReplayError = replayReply[@"lastError"];
				NSNumber *pidNum = replayReply[@"pid"];
				replayPID = pidNum.intValue;
			}
			else
			{
				if(error != NULL)
					CFRelease(error);
			}
		}

		if(action == kActionWait)
		{
			// set up belt and suspenders:
			// "replay" server is supposed to notify us before exiting
			// if this does not happen for some reason (crashed or killed)
			// we set up a "process exit" notification so we know it died and we can stop waiting
			if(replayPID != 0)
			{
				StartProcessExitMonitoring(replayPID);
			}
			
			// now wait for the server to finish its tasks and let us know
			// it is done with kCallbackMessageExiting message
			CFRunLoopRun();

			FinalizeCallbackListener(callbackListenerRef);
		}

		CFRelease(remotePort);
	}

	exit(EXIT_SUCCESS);
	return EXIT_SUCCESS;
}
