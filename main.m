//
//  main.m
//  replay
//
//  Created by Tomasz Kukielka on 8/8/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#include <pthread.h>
#include <getopt.h>
#import "ReplayAction.h"
#import "TaskProxy.h"
#import "ReplayTask.h"
#import "SerialDispatch.h"
#import "ConcurrentDispatchWithNoDependency.h"
#import "ActionStream.h"
#import "ReplayServer.h"

#if DEBUG
	#define TRACE 0
#endif

typedef enum
{
	kPlaylistFormatPlist = 0,
	kPlaylistFormatJson,
	kPlaylistFormatCount
} PlaylistFormat;

//this function is used when the playlist key is non-null so the root container must be a dictionary
static inline NSDictionary<NSString *, NSArray *> *
LoadPlaylistRootDictionary(const char* playlistPath, ReplayContext *context)
{
	if(playlistPath == NULL)
	{
		fprintf(stderr, "error: playlist file path not provided\n");
		return nil;
	}

	NSDictionary<NSString *, NSArray *> *playlistDict = nil;
	NSURL *playlistURL = [NSURL fileURLWithFileSystemRepresentation:playlistPath isDirectory:NO relativeToURL:NULL];
	
	PlaylistFormat hint = kPlaylistFormatPlist; //default to plist
	PlaylistFormat numberOfTries = 0;

	NSString *ext = [[playlistURL pathExtension] lowercaseString];
	if([ext isEqualToString:@"json"])
	{
		hint = kPlaylistFormatJson;
	}

	do
	{
		if(hint == kPlaylistFormatPlist)
		{
			playlistDict = [NSDictionary dictionaryWithContentsOfURL:playlistURL];
			NSError *loadingError = nil;
			playlistDict = [NSDictionary dictionaryWithContentsOfURL:playlistURL error:&loadingError];
			if(playlistDict != nil)
				break;
			numberOfTries++;
			hint = kPlaylistFormatJson;
		}
		else if(hint == kPlaylistFormatJson)
		{
			NSError *error = nil;
			NSData *jsonData = [NSData dataWithContentsOfURL:playlistURL options:kNilOptions error:&error];
			
			id playlistCollection = nil;
			if(jsonData != nil)
			{
				playlistCollection = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
			}

			if(playlistCollection != nil)
			{
				if([playlistCollection isKindOfClass:[NSDictionary class]])
				{
					playlistDict = (NSDictionary *)playlistCollection;
				}
				break;
			}
			numberOfTries++;
			hint = kPlaylistFormatPlist;
		}
	}
	while(numberOfTries < kPlaylistFormatCount);

	if(playlistDict == nil)
	{
		NSError *operationError = nil;
		BOOL isReachable = [playlistURL checkResourceIsReachableAndReturnError:&operationError];
		if(!isReachable)
		{
			context->lastError.error = operationError;
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];

			fprintf(stderr, "error: playlist file \"%s\" cannot be opened. Error: \"%s\"\n", [[playlistURL path] UTF8String], [errorDesc UTF8String]);
		}
		else
		{
			NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Unkown or invalid playlist type" };
			context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
			fprintf(stderr, "error: unkown or invalid playlist type. Only .plist and .json playlists are supported\nWith playlist key specified, the root container is expected to be a dictionary\n");
		}
	}

	return playlistDict;
}


// This function is used when playlistKey is null and the whole content of the file must be the playlist array

static inline NSArray<NSDictionary*> *
GetPlaylistFromRootArray(const char* playlistPath, ReplayContext *context)
{
	if(playlistPath == NULL)
	{
		fprintf(stderr, "error: playlist file path not provided\n");
		return nil;
	}

	NSArray<NSDictionary*> *playlistArray = nil;
	NSURL *playlistURL = [NSURL fileURLWithFileSystemRepresentation:playlistPath isDirectory:NO relativeToURL:NULL];
	
	PlaylistFormat hint = kPlaylistFormatPlist; //default to plist
	PlaylistFormat numberOfTries = 0;

	NSString *ext = [[playlistURL pathExtension] lowercaseString];
	if([ext isEqualToString:@"json"])
	{
		hint = kPlaylistFormatJson;
	}

	do
	{
		if(hint == kPlaylistFormatPlist)
		{
			NSError *error = nil;
			playlistArray = [NSArray arrayWithContentsOfURL:playlistURL error:&error];
			if(playlistArray != nil)
				break;
			numberOfTries++;
			hint = kPlaylistFormatJson;
		}
		else if(hint == kPlaylistFormatJson)
		{
			NSError *error = nil;
			NSData *jsonData = [NSData dataWithContentsOfURL:playlistURL options:kNilOptions error:&error];
			
			id playlistCollection = nil;
			if(jsonData != nil)
			{
				playlistCollection = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
			}

			if(playlistCollection != nil)
			{
				if([playlistCollection isKindOfClass:[NSArray class]])
				{
					playlistArray = (NSArray *)playlistCollection;
				}
				break;
			}
			numberOfTries++;
			hint = kPlaylistFormatPlist;
		}
	}
	while(numberOfTries < kPlaylistFormatCount);

	if(playlistArray == nil)
	{
		NSError *operationError = nil;
		BOOL isReachable = [playlistURL checkResourceIsReachableAndReturnError:&operationError];
		if(!isReachable)
		{
			context->lastError.error = operationError;
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];

			fprintf(stderr, "error: playlist file \"%s\" cannot be opened. Error: \"%s\"\n", [[playlistURL path] UTF8String], [errorDesc UTF8String]);
		}
		else
		{
			NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Unkown or invalid playlist type" };
			context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
			fprintf(stderr, "error: unkown or invalid playlist type. Only .plist and .json playlists are supported\nWith playlist key not specified, the root container is expected to be an array.\n");
		}
	}

	return playlistArray;
}


static struct option sLongOptions[] =
{
	{"verbose",			no_argument,		NULL, 'v'},
	{"dry-run",			no_argument,		NULL, 'n'},
	{"serial",			no_argument,		NULL, 's'},
	{"no-dependency",	no_argument,		NULL, 'p'},
	{"playlist-key",	required_argument,	NULL, 'k'},
	{"stop-on-error",   no_argument,		NULL, 'e'},
	{"force",           no_argument,		NULL, 'f'},
	{"ordered-output",  no_argument,		NULL, 'o'},
	{"start-server",    required_argument,  NULL, 'r'},
	{"help",			no_argument,		NULL, 'h'},
	{NULL, 				0, 					NULL,  0 }
};

static void
DisplayHelp(void)
{
	printf(
		"\n"
		"\n"
		"replay -- execute a declarative script of actions, aka a playlist\n"
		"\n"
		"Usage:\n"
		"\n"
		"  replay [options] [playlist_file.json|plist]\n"
		"\n"
		"Options:\n"
		"\n"
		"  -s, --serial       Execute actions serially in the order specified in the playlist (slow).\n"
		"                     Default behavior is to execute actions concurrently, if possible, after dependency analysis (fast).\n"
		"  -p, --no-dependency   An option for concurrent execution to skip dependency analysis. Actions must be independent.\n"
		"  -k, --playlist-key KEY   Use a key in root dictionary of the playlist file for action steps array.\n"
		"                     If absent, the playlist file root container is assumed to be an array of action steps.\n"
		"                     The key may be specified multiple times to execute more than one playlist in the file.\n"
		"  -e, --stop-on-error   Stop executing the remaining playlist actions on first error.\n"
		"  -f, --force        If the file operation fails, delete destination and try again.\n"
		"  -o, --ordered-output  In simple concurrent execution mode preserve the order of printed task outputs as specified\n"
		"                     in the playlist. The tasks are still executed concurrently without order guarantee\n"
		"                     but printing is ordered. Ignored in serial execution and concurrent execution with dependencies.\n"
		"  -n, --dry-run      Show a log of actions which would be performed without running them.\n"
		"  -v, --verbose      Show a log of actions while they are executed.\n"
		"  -r, --start-server BATCH_NAME   Start server and listen for dispatch requests. \"BATCH_NAME\" must be a unique name\n"
		"                     identifying a group of actions to be executed concurrently. Subsequent requests to add actions\n"
		"                     with \"dispatch\" tool must refer to the same name. \"replay\" server listens to request messages\n"
		"                     sent by \"dispatch\". If the server is not running for given batch name, the first request to add\n"
		"                     an action starts \"replay\" in server mode. Therefore staring the server manually is not required\n"
		"                     but it is possible if needed.\n"
		"  -h, --help         Display this help\n"
		"\n"
	);

	printf(
		"Playlist format:\n"
		"\n"
		"  Playlists can be composed in plist or JSON files.\n"
		"  In the usual form the root container of a plist or JSON file is a dictionary,\n"
		"  where you can put one or more playlists with unique keys.\n"
		"  A playlist is an array of action steps.\n"
		"  Each step is a dictionary with action type and parameters. See below for actions and examples.\n"
		"  If you don't specify the playlist key, the root container is expected to be an array of action steps.\n"
		"  More than one playlist may be present in a root dictionary. For example, you may want preparation steps\n"
		"  in one playlist to be executed by \"replay\" invocation with --serial option\n"
		"  and have another concurrent playlist with the bulk of work executed by a second \"replay\" invocation\n"
		"\n"
	);

	printf(
		"Environment variables expansion:\n"
		"\n"
		"  Environment variables in form of ${VARIABLE} are expanded in all paths.\n"
		"  New file content may also contain environment variables in its body (with an option to turn off expansion).\n"
		"  Missing environment variables or malformed text is considered an error and the action will not be executed.\n"
		"  It is easy to make a mistake and allowing evironment variables resolved to empty would result in invalid paths,\n"
		"  potentially leading to destructive file operations.\n"
		"\n"
	);

	printf(
		"Dependency analysis:\n"
		"\n"
		"  In default execution mode (without --serial or --no-dependency option) \"replay\" performs dependency analysis\n"
		"  and constructs an execution graph based on files consumed and produced by actions.\n"
		"  If a file produced by action A is needed by action B, action B will not be executed until action A is finished.\n"
		"  For example: if your playlist contains an action to create a directory and other actions write files\n"
		"  into this directory, all these file actions will wait for directory creation to be finished and then they will\n"
		"  be executed concurrently if otherwise independent from each other.\n"
		"  Concurrent execution imposes a couple of rules on actions:\n"
		"  1. No two actions may produce the same output. With concurrent execution this would produce undeterministic results\n"
		"     depending on which action happened to run first or fail if they accessed the same file for writing concurrently.\n"
		"     \"replay\" will not run any actions when this condition is detected during dependency analysis.\n"
		"  2. Action dependencies must not create a cycle. In other words the dependency graph must be a proper DAG.\n"
		"     An example cycle is one action copying file A to B and another action copying file B to A.\n"
		"     Replay algorithm tracks the number of unsatisifed dependencies for each action. When the number drops to zero,\n"
		"     the action is dispatched for execution. For actions in a cycle that number never drops to zero and they can\n"
		"     never be dispatched. After all dispatched tasks are done \"replay\" verifies all actions in the playlist\n"
		"     were executed and reports a failure if they were not, listing the ones which were skipped.\n"
		"  3. Deletion and creation of the same file or directory in one playlist will result in creation first and\n"
		"     deletion second because the deletion consumes the output of creation. If deletion is a required preparation step\n"
		"     it should be executed in a separate playlist before the main tasks are scheduled. You may pass --playlist-key\n"
		"     multiple times as a parameter and the playlists will be executed one after another in the order specified.\n"
		"  4. Moving or deleting an item makes it unusable for other actions at the original path. Such actions are exclusive\n"
		"     consumers of given input paths and cannot share their inputs with other actions. Producing additional items under\n"
		"     such exclusive input paths is also not allowed. \"replay\" will report an error during dependency analysis\n"
		"     and will not execute an action graph with exclusive input violations.\n"
		"\n"
	);

	printf(
		"Actions and parameters:\n"
		"\n"
		"  clone       Copy file(s) from one location to another. Cloning is supported on APFS volumes.\n"
		"              Source and destination for this action can be specified in 2 ways.\n"
		"              One to one:\n"
		"    from      Source item path.\n"
		"    to        Destination item path.\n"
		"              Or many items to destination directory:\n"
		"    items     Array of source item paths.\n"
		"    destination directory   Path to output folder.\n"
		"  copy        Synonym for clone. Functionally identical.\n"
		"  move        Move a file or directory.\n"
		"              Source and destination for this action can be specified the same way as for \"clone\".\n"
		"              Source path(s) are invalidated by \"move\" so they are marked as exclusive in concurrent execution.\n"
		"  hardlink    Create a hardlink to source file.\n"
		"              Source and destination for this action can be specified the same way as for \"clone\".\n"
		"  symlink     Create a symlink pointing to original file.\n"
		"              Source and destination for this action can be specified the same way as for \"clone\".\n"
      	"    validate   Bool value to indicate whether to check for the existence of source file. Default is true.\n"
      	"              It is usually a mistake if you try to create a symlink to nonexistent file,\n"
      	"              that is why \"validate\" is true by default but it is possible to create a dangling symlink.\n"
      	"              If you know what you are doing and really want that behavior, set \"validate\" to false.\n"
		"  create      Create a file or a directory.\n"
      	"              You can create either a file with optional content or a directory but not both in one action step.\n"
      	"    file      New file path (only for files).\n"
      	"    content   New file content string (only for files).\n"
      	"    raw       Bool value to indicate whether environment variables should be expanded or not in content text.\n"
      	"              Default value is \"false\", meaning that environment variables are expanded.\n"
      	"              Pass \"true\" if you want to write a script with some ${VARIABLE} usage\n"
      	"    directory   New directory path. All directories leading to the deepest one are created if they don't exist.\n"
		"  delete      Delete a file or directory (with its content).\n"
		"              CAUTION: There is no warning or user confirmation requested before deletion.\n"
		"    items     Array of item paths to delete (files or directories with their content).\n"
		"              Item path(s) are invalidated by \"delete\" so they are marked as exclusive in concurrent execution.\n"
		"  execute     Run an executable as a child process.\n"
		"    tool      Full path to a tool to execute.\n"
		"    arguments   Array of arguments to pass to the tool (optional).\n"
		"    inputs    Array of file paths read by the tool during execution (optional).\n"
		"    exclusive inputs    Array of file paths invalidated (items deleted or moved) by the tool (rare, optional).\n"
		"    outputs   Array of file paths writen by the tool during execution (optional).\n"
		"    stdout    Bool value to indicate whether the output of the tool should be printed to stdout (optional).\n"
		"              Default value is \"true\", indicating the output from child process is printed to stdout.\n"
		"  echo        Print a string to stdout.\n"
		"    text      The text to print.\n"
      	"    raw       Bool value to indicate whether environment variable expansion should be suppressed. Default is \"false\".\n"
      	"    newline   Bool value to indicate whether the output string should be followed by newline. Default is \"true\".\n"
		"\n"
	);


	printf(
		"Streaming actions through stdin pipe:\n"
		"\n"
		"\"replay\" allows sending a stream of actions via stdin when the playlist file is not specified.\n"
		"Actions may be executed serially or concurrently but without dependency analysis.\n"
		"Dependency analysis requires a complete set of actions to create a graph, while streaming\n"
		"starts execution immediately as the action requests arrive.\n"
		"Concurrent execution is default, which does not guarantee the order of actions but a new option:\n"
		"--ordered-output has been added to ensure the output order is the same as action scheduling order.\n"
		"For example, while streaming actions A, B, C in that order, the execution may happen like this: A, C, B\n"
		"but the printed output will still be preserved as A, B, C. This implies that that output of C\n"
		"will be delayed if B is taking long to finish.\n"
		"\n"
		"The format of streamed/piped actions is one action per line (not plist of json!), as follows:\n"
		"- ignore whitespace characters at the beginning of the line, if any\n"
		"- action and options come first in square brackets, e.g.: [clone], [move], [delete], [create file] [create directory]\n"
		"  some options can be added as key=value as described in \"Actions and parmeters\" section above with examples below\n"
		"- the first character following the closing square bracket ']' is used as a field delimiter for the parameters to the action\n"
		"- variable length parameters are following, separated by the same field separator, specific to given action\n"

		"Param interpretation per action\n"
		"(examples use \"tab\" as a separator)\n"
		"1. [clone], [move], [hardlink], [symlink] allows only simple from-to specification,\n"
		"with first param interpretted as \"from\" and second as \"to\" e.g.:\n"
		"[clone]	/path/to/src/file.txt	/path/to/dest/file.txt\n"
		"[symlink validate=false]	/path/to/src/file.txt	/path/to/symlink/file.txt\n"
		"2. [delete] is followed by one or many paths to items, e.g.:\n"
		"[delete]	/path/to/delete/file1.txt	/path/to/delete/file2.txt\n"
		"3. [create] has 2 variants: [create file] and [create directory].\n"
		"If \"file\" or \"directory\" option is not specified, it falls back to \"file\"\n"
		"A. [create file] requires path followed by optional content, e.g.:\n"
		"[create file]	/path/to/create/file.txt	Created by replay!\n"
		"[create file raw=true]	/path/to/file.txt	Do not expand environment variables like ${HOME}\n"
		"B. [create directory] requires just a single path, e.g.:\n"
		"[create directory]	/path/to/create/directory\n"
		"4. [execute] requires tool path and may have optional parameters separated with the same delimiter (not space delimited!), e.g.:\n"
		"[execute]	/bin/echo	Hello from replay!\n"
		"[execute stdout=false]	/bin/echo	This will not be printed\n"
		"In the following example uses a different separator: \"+\" to explicitly show delimited parameters:\n"
		"[execute]+/bin/sh+-c+/bin/ls ${HOME} | /usr/bin/grep \".txt\"\n"
		"5. [echo] requires one string after separator. Supported modifiers are raw=true and newline=false\n"
		"\n"
	);

	printf(
		"Example JSON playlist:\n"
		"\n"
		"{\n"
		"  \"Shepherd Playlist\": [\n"
		"    {\n"
		"      \"action\": \"create\",\n"
		"      \"directory\": \"${HOME}/Pen\",\n"
		"    },\n"
		"    {\n"
		"      \"action\": \"clone\",\n"
		"      \"from\": \"${HOME}/sheep.txt\",\n"
		"      \"to\": \"${HOME}/Pen/clone.txt\",\n"
		"    },\n"
		"    {\n"
		"      \"action\": \"move\",\n"
		"      \"items\": [\n"
		"          \"${HOME}/sheep1.txt\",\n"
		"          \"${HOME}/sheep2.txt\",\n"
		"          \"${HOME}/sheep3.txt\",\n"
		"          ],\n"
		"      \"destination directory\": \"${HOME}/Pen\",\n"
		"    },\n"
		"    {\n"
		"      \"action\": \"delete\",\n"
		"      \"items\": [\n"
		"          \"${HOME}/Pen/clone.txt\",\n"
		"          ],\n"
		"    },\n"
		"  ],\n"
		"}\n"
		"\n"
	);
	
	printf(
		"Example plist playlist:\n"
		"\n"
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
		"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
		"<plist version=\"1.0\">\n"
		"<dict>\n"
		"    <key>Shepherd Playlist</key>\n"
		"    <array>\n"
		"        <dict>\n"
		"            <key>action</key>\n"
		"            <string>create</string>\n"
		"            <key>directory</key>\n"
		"            <string>${HOME}/Pen</string>\n"
		"        </dict>\n"
		"        <dict>\n"
		"            <key>action</key>\n"
		"            <string>clone</string>\n"
		"            <key>from</key>\n"
		"            <string>${HOME}/sheep.txt</string>\n"
		"            <key>to</key>\n"
		"            <string>${HOME}/Pen/clone.txt</string>\n"
		"        </dict>\n"
		"        <dict>\n"
		"            <key>action</key>\n"
		"            <string>move</string>\n"
		"            <key>items</key>\n"
		"            <array>\n"
		"                <string>${HOME}/sheep1.txt</string>\n"
		"                <string>${HOME}/sheep2.txt</string>\n"
		"                <string>${HOME}/sheep3.txt</string>\n"
		"            </array>\n"
		"            <key>destination directory</key>\n"
		"            <string>${HOME}/Pen</string>\n"
		"        </dict>\n"
		"        <dict>\n"
		"            <key>action</key>\n"
		"            <string>delete</string>\n"
		"            <key>items</key>\n"
		"            <array>\n"
		"                <string>${HOME}/Pen/clone.txt</string>\n"
		"            </array>\n"
		"        </dict>\n"
		"    </array>\n"
		"</dict>\n"
		"</plist>\n"
		"\n"
	);

	printf(
		"Example execution:\n"
		"\n"
		"  replay --dry-run --playlist-key \"Shepherd Playlist\" shepherd.plist\n"
		"\n"
		"In the above example playlist some output files are inputs to later actions.\n"
		"The dependency analysis will create an execution graph to run dependent actions after the required outputs are produced.\n"
		"\n"
		"See also:\n"
		"\n"
		"  dispatch --help\n"
		"\n"
		"\n"
	);
}

static void
ProcessPlaylist(NSArray<NSDictionary*> *playlist, ReplayContext *context)
{
	if(context->concurrent)
	{
		context->outputSerializer = [OutputSerializer sharedOutputSerializer];
		context->actionCounter = -1;

		if(context->analyzeDependencies)
		{
			// if someone set this as a param, we need to ignore it when executing a graph of tasks
			context->orderedOutput = false;
			DispatchTasksConcurrentlyWithDependencyAnalysis(playlist, context);
		}
		else
		{
			DispatchTasksConcurrentlyWithNoDependency(playlist, context);
		}

		FlushSerializedOutputs(context->outputSerializer);
	}
	else
	{
 		// output is ordered by the virtue of serial execution
 		// but we don't want to trigger the complex infra for ordering of concurrent task outputs
 		context->outputSerializer = nil;
		context->actionCounter = -1;
		context->orderedOutput = false;
		DispatchTasksSerially(playlist, context);
	}
}


int main(int argc, const char * argv[])
{
	ReplayContext context;
	context.environment = [[NSProcessInfo processInfo] environment];
	context.lastError = [AtomicError new];
	context.fileTreeRoot = NULL;
	context.outputSerializer = nil;
	context.queue = nil;
	context.group = nil;
	context.actionCounter = -1;
	context.batchName = NULL;
	context.callbackPort = NULL;
	context.concurrent = true;
	context.analyzeDependencies = true;
	context.verbose = false;
	context.dryRun = false;
	context.stopOnError = false;
	context.force = false;
	context.orderedOutput = false;

	NSMutableArray *playlistKeys = [NSMutableArray new];

	while(true)
	{
		int index = 0;
		int oneOption = getopt_long (argc, (char * const *)argv, "vnsk:efor:h", sLongOptions, &index);
		if (oneOption == -1) //end of options is signalled by -1
			break;
			
		switch(oneOption)
		{
			case 'v':
				context.verbose = true;
			break;
			
			case 'n':
				context.dryRun = true;
			break;

			case 's':
				context.concurrent = false;
			break;

			case 'p':
				context.analyzeDependencies = false;
			break;

			case 'k':
				//multiple playlists are allowed and stored in array to dispatch one after another
				[playlistKeys addObject:@(optarg)];
			break;

			case 'e':
				context.stopOnError = true;
			break;
			
			case 'f':
				context.force = true;
			break;
			
			case 'o':
				context.orderedOutput = true;
			break;

			case 'r':
				//start server
				context.batchName = @(optarg);
			break;
			
			case 'h':
				DisplayHelp();
				return EXIT_SUCCESS;
			break;
		}
	}

	// when executed with --start-server BATCH_NAME option start server and wait for messages in runloop
	if(context.batchName != nil)
	{
		StartServerAndRunLoop(&context);
		exit((context.lastError.error != nil) ? EXIT_FAILURE : EXIT_SUCCESS);
	}

	const char *playlistPath = NULL;
	if (optind < argc)
	{
		playlistPath = argv[optind];
		optind++;
	}
	
	if(playlistPath == NULL)
	{
		StreamActionsFromStdIn(&context);
	}
	else if ([playlistKeys count] > 0)
	{
		NSDictionary<NSString *, NSArray *> *playlistRootDict = LoadPlaylistRootDictionary(playlistPath, &context);
		if(playlistRootDict == nil)
		{
			printf("Invalid or empty playlist \"%s\". No steps to replay\n", playlistPath);
			return EXIT_SUCCESS;
		}
		
		Class arrayClass = [NSArray class];

		for(NSString *oneKey in playlistKeys)
		{
			NSArray<NSDictionary*> *playlist = playlistRootDict[oneKey];
			if((playlist == nil) || !([playlist isKindOfClass:arrayClass]))
			{
				printf("Invalid or empty playlist for key \"%s\". No steps to replay\n", [oneKey UTF8String]);
				if(context.stopOnError)
					break;
			}
			ProcessPlaylist(playlist, &context);
		}
	}
	else
	{
		NSArray<NSDictionary*> *playlist = GetPlaylistFromRootArray(playlistPath, &context);
		if(playlist == nil)
		{
			printf("Invalid or empty playlist \"%s\". No steps to replay\n", playlistPath);
			return EXIT_SUCCESS;
		}
		ProcessPlaylist(playlist, &context);
	}

	// It looks like a lot of unnecessary Obj-C memory cleanup is happening at exit
	// and takes long time so skip it and just terminate the app now

	if(context.lastError.error != nil)
		exit(EXIT_FAILURE);

	exit(EXIT_SUCCESS);

	return EXIT_SUCCESS; //unreachable
}
