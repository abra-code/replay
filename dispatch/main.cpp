//
//  main.cpp
//  dispatch
//
//  Created by Tomasz Kukielka on 12/23/20.
//

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <unistd.h>

#include <string>
#include <string_view>
#include <vector>

#include "replay_server.h"
#include "ActionFromName.h"
#include "replay_version.h"
#include "CFObj.h"
#include "CFStr.h"
#include "CFArr.h"
#include "CFDict.h"
#include "ChildProcess.h"

static bool
StartChildProcess(const std::string &toolPath, const std::vector<std::string> &arguments)
{
	ChildProcess::Options opts;
	opts.argv.reserve(arguments.size() + 1);
	opts.argv.emplace_back(toolPath);
	for (const std::string &arg : arguments)
		opts.argv.emplace_back(arg);
	opts.detach = true; // fire-and-forget; replay server runs independently

	ChildProcess::Result r = ChildProcess::Run(opts);
	if (!r.launched)
	{
		fprintf(stderr, "error: failed to execute \"%s\". %s\n",
		        toolPath.c_str(), r.launch_error.c_str());
		return false;
	}
	return true;
}


static CFDataRef
CallbackProc(CFMessagePortRef inLocalPort, SInt32 inMessageID, CFDataRef /*inData*/, void * /*info*/)
{
	if (inMessageID == kCallbackMessageHeartbeat)
	{
		// replay reports it is alive when we wait
	}
	else if (inMessageID == kCallbackMessageExiting)
	{
		CFMessagePortInvalidate(inLocalPort);
		CFRunLoopStop(CFRunLoopGetCurrent());
	}

	return nullptr;
}


static CFRunLoopSourceRef
StartCallbackListener(const std::string &batchName)
{
	CFStr batchStr(batchName);
	CFStr portName = CFStr::Format(kDispatchListenerPortFormat, GetAppGroupIdentifier(), (CFStringRef)batchStr);
	if (portName == nullptr)
	{
		fprintf(stderr, "error: could not create port name\n");
		exit(EXIT_FAILURE);
	}

	CFMessagePortContext messagePortContext = { 0, nullptr, nullptr, nullptr, nullptr };
	CFObj<CFMessagePortRef> localPort(
		CFMessagePortCreateLocal(kCFAllocatorDefault, portName, CallbackProc, &messagePortContext, nullptr),
		kCFObjDontRetain);
	if (localPort == nullptr)
	{
		fprintf(stderr, "error: could not create a local message port\n");
		exit(EXIT_FAILURE);
	}

	CFObj<CFRunLoopSourceRef> runLoopSource(
		CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, localPort, 0),
		kCFObjDontRetain);
	if (runLoopSource == nullptr)
	{
		fprintf(stderr, "error: could not create a runloop source\n");
		exit(EXIT_FAILURE);
	}

	CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
	return runLoopSource.Detach();
}

static void
FinalizeCallbackListener(CFRunLoopSourceRef runLoopSource)
{
	if (runLoopSource != nullptr)
	{
		CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
		CFRelease(runLoopSource);
	}
}

static void
StartProcessExitMonitoring(int pid)
{
	dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
		DISPATCH_PROC_EXIT, dispatch_get_main_queue());
	if (source != nullptr)
	{ // source is non-null even if the process does not exist;
	  // we immediately receive the exit event in that race-condition case
		dispatch_source_set_event_handler(source, ^{
			dispatch_source_cancel(source);
			CFRunLoopStop(CFRunLoopGetCurrent());
		});
		dispatch_resume(source);
		// GCD retains internally while pending — safe to release our reference
		dispatch_release(source);
	}
}


static CFMessagePortRef
StartReplayAndOpenRemotePort(const std::string &pathToDispatch, CFStringRef portName,
                             const std::vector<std::string> &arguments, bool ensureResponse)
{
	CFMessagePortRef remotePort = nullptr;

	// replay is expected to be in the same directory as dispatch
	std::string replayPath;
	{
		size_t slashPos = pathToDispatch.find_last_of('/');
		if (slashPos != std::string::npos)
			replayPath = pathToDispatch.substr(0, slashPos + 1) + "replay";
		else
			replayPath = "replay";
	}

	bool replayStarted = StartChildProcess(replayPath, arguments);
	if (replayStarted)
	{
		for (int i = 0; i < 30; i++)
		{
			// retry opening the communication port with "replay"
			remotePort = CFMessagePortCreateRemote(kCFAllocatorDefault, portName);
			if (remotePort != nullptr)
				break;
			usleep(100000); // sleep 0.1 sec
		}

		if (remotePort == nullptr)
		{
			fprintf(stderr, "error: could not communicate with \"replay\"\n");
		}
	}
	else
	{
		struct stat st;
		if (stat(replayPath.c_str(), &st) != 0)
		{
			fprintf(stderr, "error: \"replay\" not found at %s\n", replayPath.c_str());
		}
	}

	if ((remotePort != nullptr) && ensureResponse)
	{ // try sending a test message to see if we get a response
		for (int i = 0; i < 10; i++)
		{
			CFDataRef replayReplyData = nullptr;
			int result = CFMessagePortSendRequest(remotePort, kReplayMessageStartServer, nullptr,
				10/*send timeout*/, 10/*rcv timeout*/, kCFRunLoopDefaultMode, &replayReplyData);

			if (result == 0)
			{
				if (replayReplyData != nullptr)
					CFRelease(replayReplyData);
				break;
			}
			usleep(100000); // sleep 0.1 sec
		}
	}

	return remotePort;
}


static int
SendActionsFromStdIn(CFMessagePortRef remotePort)
{
	int result = 0;
	char *line = nullptr;
	size_t linecap = 0;
	ssize_t linelen;
	while ((linelen = getline(&line, &linecap, stdin)) > 0)
	{
		CFObj<CFDataRef> lineData(CFDataCreate(kCFAllocatorDefault, (const UInt8 *)line, linelen));
		if (lineData != nullptr)
		{
			result = CFMessagePortSendRequest(remotePort, kReplayMessageQueueActionLine, lineData,
				10/*send timeout*/, 0/*rcv timeout*/, nullptr, nullptr);
			if (result != 0)
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

	// do not bother freeing the line buffer - the process is ending
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
		"   create file /path/to/new/file blob <base64>\n"
		"   create directory /path/to/new/dir\n"
		"   delete /path/to/item1 /path/to/item2 /path/to/itemN\n"
		"   read /path/to/item1 /path/to/item2 /path/to/itemN\n"
		"   list /path/to/directory\n"
		"   tree /path/to/directory [depth]\n"
		"   info /path/to/file/or/directory\n"
		"   glob /root/dir **/*.ext [more/**/*.ext ...] [!exclude/**]\n"
		"   edit /path/to/file.txt <oldText> <newText> [regex=true] [limit=N] [case-insensitive=true]\n"
		"   edit /path/to/src/*.cpp <oldText> <newText>   (glob: all matches edited by one task)\n"
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


// dispatch batch_name action_name <action params>

int main(int argc, const char *argv[])
{
	if (argc < 2)
	{
		DisplayHelp();
		return EXIT_FAILURE;
	}

	int result = 0;
	std::string pathToDispatchFromArg = argv[0];
	std::string batchName = argv[1];
	std::string actionName;
	int lastArgIndex = argc - 1;
	int currArgIndex = 2;

	if ((argc == 2) && ((batchName == "--help") || (batchName == "-h")))
	{
		DisplayHelp();
		return EXIT_SUCCESS;
	}

	if ((argc == 2) && ((batchName == "--version") || (batchName == "-V")))
	{
		printf("dispatch %s\n", STRINGIFY_VALUE(REPLAY_VERSION));
		return EXIT_SUCCESS;
	}

	CFStr batchStr(batchName);
	CFStr portName = CFStr::Format(kReplayServerPortFormat, GetAppGroupIdentifier(), (CFStringRef)batchStr);
	if (portName == nullptr)
	{
		fprintf(stderr, "error: could not create port name\n");
		exit(EXIT_FAILURE);
	}

	bool isSrcDestAction = false;
	Action action = kActionInvalid;
	if (argc > 2)
	{
		actionName = argv[2];
		action = ActionFromName(std::string_view(argv[2]), isSrcDestAction);
	}

	CFObj<CFMessagePortRef> remotePort(
		CFMessagePortCreateRemote(kCFAllocatorDefault, portName),
		kCFObjDontRetain); // should return non-null if remote server port already created
	if (remotePort == nullptr)
	{
		if (action != kActionWait)
		{
			std::vector<std::string> arguments;
			arguments.emplace_back("--start-server"); // this is mandatory arg
			arguments.emplace_back(batchName);

			if (action == kActionStartServer) // this is for explicit "start" action specified
			{ // additional args are params for replay tools
				while (currArgIndex < lastArgIndex)
				{
					currArgIndex++;
					arguments.emplace_back(argv[currArgIndex]);
				}
			}

			// port not open, launch "replay" with batch name and specified params
			bool ensureResponse = (action != kActionStartServer); // when starting the server one message will be sent by default

			std::string pathToDispatch = pathToDispatchFromArg; // fallback path
			char dispatchPath[PATH_MAX] = {0};
			uint32_t buffSize = PATH_MAX;
			int execResult = _NSGetExecutablePath(dispatchPath, &buffSize); // get real executable path
			if (execResult == 0)
				pathToDispatch = dispatchPath;

			remotePort.Adopt(StartReplayAndOpenRemotePort(pathToDispatch, portName, arguments, ensureResponse),
				kCFObjDontRetain);
		}
		else
		{
			fprintf(stderr, "warning: \"replay\" server not running for batch name \"%s\"\n", batchName.c_str());
		}
	}
	else if (action == kActionStartServer)
	{
		fprintf(stderr, "warning: \"replay\" server already running for batch name \"%s\"\n", batchName.c_str());
	}

	if (remotePort == nullptr)
		exit(EXIT_FAILURE);

	if (argc == 2)
	{ // this is the mode where only "dispatch batch_name" is used and the action description
	  // is read-in from stdin in the delimited format the same as "replay" uses
		result = SendActionsFromStdIn(remotePort);
		exit((result == 0) ? EXIT_SUCCESS : EXIT_FAILURE);
	}

	CFRunLoopSourceRef callbackListenerRef = nullptr;
	CFMutableDict actionDescription;
	{
		CFStr actionNameStr(actionName);
		actionDescription.SetValue(CFSTR("action"), actionNameStr);
	}

	SInt32 msgid = kReplayMessageQueueActionDictionary;

	if (isSrcDestAction)
	{ // these require 2 arguments
	  // kFileActionClone
	  // kFileActionMove
	  // kFileActionHardlink
	  // kFileActionSymlink

		if (currArgIndex < lastArgIndex)
		{
			currArgIndex++;
			CFStr fromStr(argv[currArgIndex]);
			actionDescription.SetValue(CFSTR("from"), fromStr);
		}
		else
		{
			fprintf(stderr, "error: \"%s\" action requires exactly two paths\n", actionName.c_str());
			exit(EXIT_FAILURE);
		}

		if (currArgIndex < lastArgIndex)
		{
			currArgIndex++;
			CFStr toStr(argv[currArgIndex]);
			actionDescription.SetValue(CFSTR("to"), toStr);
		}
		else
		{
			fprintf(stderr, "error: \"%s\" action requires exactly two paths\n", actionName.c_str());
			exit(EXIT_FAILURE);
		}
	}
	else
	{
		switch (action)
		{
			case kActionStartServer:
			{
				msgid = kReplayMessageStartServer;
			}
			break;

			case kFileActionCreate:
			{
				const char *typeStr = nullptr;
				if (currArgIndex < lastArgIndex)
				{
					currArgIndex++;
					typeStr = argv[currArgIndex];
				}
				else
				{
					fprintf(stderr, "error: \"create\" action requires \"file\" or \"directory\" specification and a path\n");
					exit(EXIT_FAILURE);
				}

				std::string_view type(typeStr);
				if (currArgIndex < lastArgIndex)
				{
					currArgIndex++;
					CFStr pathStr(argv[currArgIndex]);

					if (type == "directory")
					{
						actionDescription.SetValue(CFSTR("directory"), pathStr);
					}
					else if (type == "file")
					{
						actionDescription.SetValue(CFSTR("file"), pathStr);
						if (currArgIndex < lastArgIndex)
						{ // optional content or blob
							currArgIndex++;
							std::string_view nextArg(argv[currArgIndex]);
							if (nextArg == "blob")
							{ // create file blob /path <base64>
								if (currArgIndex < lastArgIndex)
								{
									currArgIndex++;
									CFStr blobStr(argv[currArgIndex]);
									actionDescription.SetValue(CFSTR("blob"), blobStr);
								}
								else
								{
									fprintf(stderr, "error: \"create file blob\" requires a base64 string after the path\n");
									exit(EXIT_FAILURE);
								}
							}
							else
							{
								CFStr contentStr(nextArg);
								actionDescription.SetValue(CFSTR("content"), contentStr);
							}
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
				if (currArgIndex < lastArgIndex)
				{
					CFMutableArr paramArray;
					while (currArgIndex < lastArgIndex)
					{
						currArgIndex++;
						CFStr onePath(argv[currArgIndex]);
						paramArray.AppendValue(onePath);
					}
					actionDescription.SetValue(CFSTR("items"), paramArray);
				}
				else
				{
					fprintf(stderr, "error: \"delete\" action requires at least one path\n");
					exit(EXIT_FAILURE);
				}
			}
			break;

			case kFileActionRead:
			{ // variable element input - all params are paths to read
				if (currArgIndex < lastArgIndex)
				{
					CFMutableArr paramArray;
					while (currArgIndex < lastArgIndex)
					{
						currArgIndex++;
						CFStr onePath(argv[currArgIndex]);
						paramArray.AppendValue(onePath);
					}
					actionDescription.SetValue(CFSTR("items"), paramArray);
				}
				else
				{
					fprintf(stderr, "error: \"read\" action requires at least one path\n");
					exit(EXIT_FAILURE);
				}
			}
			break;

			case kFileActionList:
			{ // single directory path
				if (currArgIndex < lastArgIndex)
				{
					currArgIndex++;
					CFStr dirStr(argv[currArgIndex]);
					actionDescription.SetValue(CFSTR("directory"), dirStr);
				}
				else
				{
					fprintf(stderr, "error: \"list\" action requires a directory path\n");
					exit(EXIT_FAILURE);
				}
			}
			break;

			case kFileActionTree:
			{ // single directory path with optional depth
				if (currArgIndex < lastArgIndex)
				{
					currArgIndex++;
					CFStr dirStr(argv[currArgIndex]);
					actionDescription.SetValue(CFSTR("directory"), dirStr);
				}
				else
				{
					fprintf(stderr, "error: \"tree\" action requires a directory path\n");
					exit(EXIT_FAILURE);
				}
				// optional depth argument
				if (currArgIndex < lastArgIndex)
				{
					const char *maybeDepth = argv[currArgIndex + 1];
					char *end = nullptr;
					long depth = strtol(maybeDepth, &end, 10);
					if ((end != maybeDepth) && (*end == '\0'))
					{
						currArgIndex++;
						actionDescription.SetValue(CFSTR("depth"), (CFIndex)depth);
					}
				}
			}
			break;

			case kFileActionInfo:
			{ // single path (file or directory)
				if (currArgIndex < lastArgIndex)
				{
					currArgIndex++;
					CFStr pathStr(argv[currArgIndex]);
					actionDescription.SetValue(CFSTR("path"), pathStr);
				}
				else
				{
					fprintf(stderr, "error: \"info\" action requires a path\n");
					exit(EXIT_FAILURE);
				}
			}
			break;

			case kFileActionGlob:
			{ // first arg is root dir; remaining non-'!'-prefixed args are relative glob patterns; '!'-prefixed are excludes
				if (currArgIndex >= lastArgIndex)
				{
					fprintf(stderr, "error: \"glob\" action requires a root directory and at least one pattern\n");
					exit(EXIT_FAILURE);
				}
				currArgIndex++;
				CFStr rootStr(argv[currArgIndex]);
				actionDescription.SetValue(CFSTR("root"), rootStr);
				CFMutableArr globs;
				CFMutableArr excludes;
				while (currArgIndex < lastArgIndex)
				{
					currArgIndex++;
					std::string_view arg(argv[currArgIndex]);
					if (!arg.empty() && (arg.front() == '!'))
					{
						CFStr s(arg.substr(1));
						excludes.AppendValue(s);
					}
					else
					{
						CFStr s(arg);
						globs.AppendValue(s);
					}
				}
				if (globs.GetCount() == 0)
				{
					fprintf(stderr, "error: \"glob\" action requires at least one positive pattern\n");
					exit(EXIT_FAILURE);
				}
				actionDescription.SetValue(CFSTR("glob"), globs);
				if (excludes.GetCount() > 0)
					actionDescription.SetValue(CFSTR("exclude"), excludes);
			}
			break;

			case kFileActionEdit:
			{ // file oldText newText [regex=true] [limit=N] [case-insensitive=true]
				if ((currArgIndex + 2) >= lastArgIndex)
				{
					fprintf(stderr, "error: \"edit\" action requires a file path, oldText, and newText (use \"\" to delete)\n");
					exit(EXIT_FAILURE);
				}
				currArgIndex++;
				{
					CFMutableArr items;
					CFStr pathStr(argv[currArgIndex]);
					items.AppendValue(pathStr);
					actionDescription.SetValue(CFSTR("items"), items);
				}
				currArgIndex++;
				{
					CFStr oldText(argv[currArgIndex]);
					actionDescription.SetValue(CFSTR("oldText"), oldText);
				}
				currArgIndex++;
				{
					CFStr newText(argv[currArgIndex]);
					actionDescription.SetValue(CFSTR("newText"), newText);
				}
				while (currArgIndex < lastArgIndex)
				{
					currArgIndex++;
					std::string_view opt(argv[currArgIndex]);
					if (opt.starts_with("regex="))
						actionDescription.SetValue(CFSTR("regex"), opt.substr(6) == "true");
					else if (opt.starts_with("limit="))
						actionDescription.SetValue(CFSTR("limit"), (CFIndex)strtol(argv[currArgIndex] + 6, nullptr, 10));
					else if (opt.starts_with("case-insensitive="))
						actionDescription.SetValue(CFSTR("case-insensitive"), opt.substr(17) == "true");
					else
						fprintf(stderr, "warning: unknown \"edit\" option ignored: %s\n", argv[currArgIndex]);
				}
			}
			break;

			case kActionExecuteTool:
			{
				if (currArgIndex < lastArgIndex)
				{
					currArgIndex++;
					CFStr toolStr(argv[currArgIndex]);
					actionDescription.SetValue(CFSTR("tool"), toolStr);
				}
				else
				{
					fprintf(stderr, "error: \"execute\" action requires a path to a tool\n");
					exit(EXIT_FAILURE);
				}

				if (currArgIndex < lastArgIndex)
				{
					CFMutableArr args;
					while (currArgIndex < lastArgIndex)
					{
						currArgIndex++;
						CFStr onePath(argv[currArgIndex]);
						args.AppendValue(onePath);
					}
					actionDescription.SetValue(CFSTR("arguments"), args);
				}
			}
			break;

			case kActionEcho:
			{
				if (currArgIndex < lastArgIndex)
				{
					currArgIndex++;
					CFStr textStr(argv[currArgIndex]);
					actionDescription.SetValue(CFSTR("text"), textStr);
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
				fprintf(stderr, "error: invalid \"replay\" action: %s\n", actionName.c_str());
				exit(EXIT_FAILURE);
			break;
		}
	}

	CFDataRef replayReplyData = nullptr;
	CFObj<CFDataRef> plistData(CFPropertyListCreateData(kCFAllocatorDefault, actionDescription,
		kCFPropertyListBinaryFormat_v1_0, 0, nullptr));
	if (plistData != nullptr)
	{
		result = CFMessagePortSendRequest(remotePort, msgid, plistData,
			10/*send timeout*/, 10/*rcv timeout*/, kCFRunLoopDefaultMode, &replayReplyData);
		plistData.Release();
		if (result != 0)
		{
			fprintf(stderr, "error: could not send dispatch request to \"replay\": %d\n", result);
			exit(EXIT_FAILURE);
		}
	}

	int replayPID = 0;
	if (replayReplyData != nullptr)
	{
		CFErrorRef error = nullptr;
		CFObj<CFPropertyListRef> replyPlist(CFPropertyListCreateWithData(kCFAllocatorDefault, replayReplyData,
			kCFPropertyListImmutable, nullptr, &error));
		CFRelease(replayReplyData);
		CFDictionaryRef replyDict = nullptr;
		if ((replyPlist != nullptr) && CFType<CFDictionaryRef>::DynamicCast(replyPlist, replyDict))
		{
			CFDict replayReply(replyDict);
			// lastError extracted but unused — match original behavior
			int64_t pid64 = 0;
			if (replayReply.GetValue(CFSTR("pid"), pid64))
				replayPID = (int)pid64;
		}
		else if (error != nullptr)
		{
			CFRelease(error);
		}
	}

	if (action == kActionWait)
	{
		// set up belt and suspenders:
		// "replay" server is supposed to notify us before exiting;
		// if this does not happen for some reason (crashed or killed)
		// we set up a "process exit" notification so we know it died and we can stop waiting
		if (replayPID != 0)
			StartProcessExitMonitoring(replayPID);

		// now wait for the server to finish its tasks and let us know
		// it is done with kCallbackMessageExiting message
		CFRunLoopRun();

		FinalizeCallbackListener(callbackListenerRef);
	}

	exit(EXIT_SUCCESS);
	return EXIT_SUCCESS;
}
