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

#if DEBUG
	#define TRACE 0
#endif

typedef enum
{
	kPlaylistFormatPlist = 0,
	kPlaylistFormatJson,
	kPlaylistFormatCount
} PlaylistFormat;

typedef struct
{
	NSDictionary<NSString *,NSString *> *environment;
	bool concurrent;
	bool verbose;
	bool dryRun;
} PlaylistSettings;


static NSString *
StringByExpandingEnvironmentVariables(NSString *origString, NSDictionary<NSString *,NSString *> *environment, bool verbose)
{
	unichar stackBuffer[PATH_MAX];
	unichar *uniChars = NULL;
	NSUInteger length = [origString length];
	if(length < PATH_MAX)
	{//in most common case we will fit in on-stack buffer and save
		uniChars = stackBuffer;
	}
	else
	{
		uniChars = (unichar*)malloc((length+1)*sizeof(unichar));
		if(uniChars == NULL)
			return nil;
	}

	NSRange wholeRange = NSMakeRange(0, length);
	[origString getCharacters:uniChars range:wholeRange];
	
	//null-terminate just for sanity
	uniChars[length] = (unichar)0;

	NSMutableArray *stringChunks = [NSMutableArray array];
	
	bool isMalformed = false;
	NSUInteger chunkStart = 0;
	for(NSUInteger i = 0; i < length; i++)
	{
		//minimal env var sequence is 4 chars: ${A}
		if((uniChars[i] == (unichar)'$') && ((i+3) < length) && (uniChars[i+1] == (unichar)'{'))
		{
			//flush previous chunk if any
			if(i > chunkStart)
			{
				NSString *chunk = [NSString stringWithCharacters:&uniChars[chunkStart] length:(i-chunkStart)];
				[stringChunks addObject:chunk];
			}

			i += 2;// skip ${
			chunkStart = i; //chunkStart point to the first char in env name
			
			//forward to the end of the ${FOO} block
			
			while((i < length) && (uniChars[i] != (unichar)'}'))
			{
				++i;
			}
			
			//if '}' found before the end of string, i points to '}' char
			if(i < length)
			{
				NSString *envVarName = [NSString stringWithCharacters:&uniChars[chunkStart] length:(i-chunkStart)];
				NSString *envValue = environment[envVarName];
				if(envValue == nil)
				{
					 //In debug and verbose mode warn about referenced env variable that is missing
#if !DEBUG
					if (verbose)
#endif
					{
						fprintf(stderr, "Referenced environment variable \"%s\" not found\n", [envVarName UTF8String]);
					}
				}
				else
				{//add only found env variable values
					[stringChunks addObject:envValue];
				}
				chunkStart = i+1; //do not increment "i" here. for loop will do it in the next iteration
			}
			else //unterminated ${} sequence - return nil
			{
				 //In debug and verbose mode warn about unterminated env variable sequence
#if !DEBUG
				if (verbose)
#endif
				{
					//translate the error to 1-based index
					fprintf(stderr, "Unterminated environment variable sequence at character %lu in string \"%s\"\n", chunkStart-1, [origString UTF8String]);
				}
				isMalformed = true;
				break;
			}
		}
	}

	//finished scanning the string. Check if any tail chunk left not flushed
	if(chunkStart < length) // example test: ${A}B - len=5, chunkStart=4
	{
		NSString *chunk = [NSString stringWithCharacters:&uniChars[chunkStart] length:(length-chunkStart)];
		[stringChunks addObject:chunk];
	}

	if(uniChars != stackBuffer)
	{
		free(uniChars);
	}

	NSString *expandedString = nil;
	if(!isMalformed)
		expandedString = [stringChunks componentsJoinedByString:@""];

	return expandedString;
}

// if the playlistKey is specified, the playlist array is expected to be embedded in the root dictionary in the file
// if the playlistKey is NULL, the whole content of the file is expected to be playlist array

static inline NSArray<NSDictionary*> *
GetPlaylist(const char* playlistPath, const char* playlistKey)
{
	if(playlistPath == NULL)
	{
		fprintf(stderr, "Playlist file path not provided\n");
		return nil;
	}

	NSArray<NSDictionary*> *playlistArray = nil;
	NSDictionary *playlistDict = nil;
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
			if(playlistKey != NULL)
			{
				playlistDict = [NSDictionary dictionaryWithContentsOfURL:playlistURL];
				if(playlistDict != nil)
					break;
			}
			else
			{
				playlistArray = [NSArray arrayWithContentsOfURL:playlistURL];
				if(playlistArray != nil)
					break;
			}
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
					//playlistKey is ignored even if not NULL
					playlistArray = (NSArray *)playlistCollection;
				}
				else if([playlistCollection isKindOfClass:[NSDictionary class]] && (playlistKey != NULL))
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

	if((playlistDict == nil) && (playlistArray == nil))
	{
		NSError *operationError = nil;
		BOOL isReachable = [playlistURL checkResourceIsReachableAndReturnError:&operationError];
		if(!isReachable)
		{
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
				errorDesc = [operationError localizedFailureReason];

			fprintf(stderr, "Playlist file \"%s\" cannot be opened. Error: \"%s\"\n", [[playlistURL path] UTF8String], [errorDesc UTF8String]);
		}
		else
		{
			fprintf(stderr, "Unkown or invalid playlist type. Only .plist and .json playlists are supported\nIf -playlistKey is specified, the root container is expected to be a dictionary. The playlist itself is always an array\n");
		}
	}


	if(playlistKey != NULL)
	{
		NSString *key = @(playlistKey); // [NSString stringWithUTF8String:playlistKey];
		playlistArray = playlistDict[key];
		if(playlistArray == nil)
		{
			fprintf(stderr, "Playlist array not found for key \"%s\" in file \"%s\"\n", [key UTF8String], [[playlistURL path] UTF8String]);
		}
	}

#if TRACE
	NSLog(@"playlistArray = %@", playlistArray);
#endif

	return playlistArray;
}

static bool
CloneItem(NSURL *fromURL, NSURL *toURL, const PlaylistSettings *settings)
{
	if(settings->verbose || settings->dryRun)
	{
		fprintf(stdout, "[clone]	%s	%s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String]);
	}

	bool isSuccessful = settings->dryRun;
	if(!settings->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;
		isSuccessful = (bool)[fileManager copyItemAtURL:(NSURL *)fromURL  toURL:(NSURL *)toURL error:&operationError];
		if(!isSuccessful)
		{
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
			{
				errorDesc = [operationError localizedFailureReason];
			}
			fprintf(stderr, "Failed to clone from \"%s\" to \"%s\". Error: %s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

static bool
MoveItem(NSURL *fromURL, NSURL *toURL, const PlaylistSettings *settings)
{
	if(settings->verbose || settings->dryRun)
	{
		fprintf(stdout, "[move]	%s	%s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String]);
	}

	bool isSuccessful = settings->dryRun;
	if(!settings->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;
		isSuccessful = (bool)[fileManager moveItemAtURL:fromURL toURL:toURL error:&operationError];
		if(!isSuccessful)
		{
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
			{
				errorDesc = [operationError localizedFailureReason];
			}
			fprintf(stderr, "Failed to move from \"%s\" to \"%s\". Error: %s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

static bool
HardlinkItem(NSURL *fromURL, NSURL *toURL, const PlaylistSettings *settings)
{
	if(settings->verbose || settings->dryRun)
	{
		fprintf(stdout, "[hardlink]	%s	%s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String]);
	}

	bool isSuccessful = settings->dryRun;
	if(!settings->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;
		isSuccessful = (bool)[fileManager linkItemAtURL:fromURL toURL:toURL error:&operationError];
		if(!isSuccessful)
		{
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
			{
				errorDesc = [operationError localizedFailureReason];
			}
			fprintf(stderr, "Failed to create a hardlink from \"%s\" to \"%s\". Error: %s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

static bool
SymlinkItem(NSURL *fromURL, NSURL *linkURL, const PlaylistSettings *settings)
{
	if(settings->verbose || settings->dryRun)
	{
		fprintf(stdout, "[symlink]	%s	%s\n", [[fromURL path] UTF8String], [[linkURL path] UTF8String]);
	}

	bool isSuccessful = settings->dryRun;
	if(!settings->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;
		isSuccessful = (bool)[fileManager createSymbolicLinkAtURL:linkURL withDestinationURL:(NSURL *)fromURL error:&operationError];
		if(!isSuccessful)
		{
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
			{
				errorDesc = [operationError localizedFailureReason];
			}
			fprintf(stderr, "Failed to create a symlink at \"%s\" referring to \"%s\". Error: %s\n", [[linkURL path] UTF8String], [[fromURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

static bool
CreateFile(NSURL *itemURL, NSString *content, const PlaylistSettings *settings)
{
	if(settings->verbose || settings->dryRun)
	{
		//TODO: escape newlines for multiline text so it will be displayed in one line
		fprintf(stdout, "[create]	%s	%s\n", [[itemURL path] UTF8String], [content UTF8String]);
	}

	bool isSuccessful = settings->dryRun;
	if(!settings->dryRun)
	{
		NSError *operationError = nil;
		isSuccessful = [content writeToURL:itemURL atomically:NO encoding:NSUTF8StringEncoding error:&operationError];
		if(!isSuccessful)
		{
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
			{
				errorDesc = [operationError localizedFailureReason];
			}
			fprintf(stderr, "Failed to create file \"%s\". Error: %s\n", [[itemURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

static bool
CreateDirectory(NSURL *itemURL, const PlaylistSettings *settings)
{
	if(settings->verbose || settings->dryRun)
	{
		fprintf(stdout, "[create]	%s\n", [[itemURL path] UTF8String]);
	}

	bool isSuccessful = settings->dryRun;
	if(!settings->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;
		isSuccessful = [fileManager createDirectoryAtURL:itemURL withIntermediateDirectories:YES attributes:nil error:&operationError];
		
		if(!isSuccessful)
		{
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
			{
				errorDesc = [operationError localizedFailureReason];
			}
			fprintf(stderr, "Failed to create directory \"%s\". Error: %s\n", [[itemURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

static bool
DeleteItem(NSURL *itemURL, const PlaylistSettings *settings)
{
	if(settings->verbose || settings->dryRun)
	{
		fprintf(stdout, "[delete]	%s\n", [[itemURL path] UTF8String]);
	}

	bool isSuccessful = settings->dryRun;
	if(!settings->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;
		isSuccessful = (bool)[fileManager removeItemAtURL:itemURL error:&operationError];
		if(!isSuccessful)
		{
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
			{
				errorDesc = [operationError localizedFailureReason];
			}
			fprintf(stderr, "Failed to delete \"%s\". Error: %s\n", [[itemURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}


static NSArray<NSURL*> *
ItemPathsToURLs(NSArray<NSString*> *itemPaths, const PlaylistSettings *settings)
{
	NSUInteger fileCount = [itemPaths count];
	NSMutableArray *itemURLs = [NSMutableArray arrayWithCapacity:fileCount];
	
	for(NSString *itemPath in itemPaths)
	{
		NSString *expandedFileName = StringByExpandingEnvironmentVariables(itemPath, settings->environment, settings->verbose);
		if(expandedFileName == nil)
		{
			//one broken path breaks all
			return nil;
		}
		NSURL *itemURL = [NSURL fileURLWithPath:expandedFileName];
		[itemURLs addObject:itemURL];
	}

	return itemURLs;
}

//when an operation is specified as a list of source items and destination dir
//create explicit list of destination URLs corresponding to source file names
//if more than one source file happens to have the same name, items will be overwritten

static NSArray<NSURL*> *
GetDestinationsForMultipleItems(NSArray<NSURL*> *sourceItemURLs, NSURL *destinationDirectoryURL, const PlaylistSettings *settings)
{
	if(destinationDirectoryURL == nil)
		return nil;

	NSUInteger itemCount = [sourceItemURLs count];
	NSMutableArray *destinationURLs = [NSMutableArray arrayWithCapacity:itemCount];
	
	for(NSURL *srcItemURL in sourceItemURLs)
	{
		NSString *fileName = [srcItemURL lastPathComponent];
    	NSURL *destURL = [destinationDirectoryURL URLByAppendingPathComponent:fileName];
		[destinationURLs addObject:destURL];
	}

	return destinationURLs;
}


typedef enum
{
	kFileActionInvalid,
	kFileActionClone,
	kFileActionMove,
	kFileActionHardlink,
	kFileActionSymlink,
	kFileActionCreate,
	kFileActionDelete,
} FileAction;


static inline void
DispatchAction(dispatch_queue_t queue, dispatch_group_t group, dispatch_block_t action)
{
	if(action != NULL)
	{
		if(group != NULL)
		{//concurrent queue
			dispatch_group_async(group, queue, action);
		}
		else
		{//serial queue
			dispatch_async(queue, action);
		}
	}
}

static void
DispatchOneSourceDestinationAction(dispatch_queue_t queue, dispatch_group_t group, FileAction fileAction, NSURL *sourceURL, NSURL *destinationURL, const PlaylistSettings *settings)
{
	if((sourceURL == nil) || (destinationURL == nil))
		return;

	dispatch_block_t action = NULL;
	switch(fileAction)
	{
		case kFileActionClone:
		{
			action = ^{
				__unused bool isOK = CloneItem(sourceURL, destinationURL, settings);
			};
		}
		break;

		case kFileActionMove:
		{
			action = ^{
				__unused bool isOK = MoveItem(sourceURL, destinationURL, settings);
			};
		}
		break;
		
		case kFileActionHardlink:
		{
			action = ^{
				__unused bool isOK = HardlinkItem(sourceURL, destinationURL, settings);
			};
		}
		break;

		case kFileActionSymlink:
		{
			action = ^{
				__unused bool isOK = SymlinkItem(sourceURL, destinationURL, settings);
			};
		}
		break;
		
		default:
		{
		}
		break;
	}
	DispatchAction(queue, group, action);
}

static void
DispatchStep(NSDictionary *stepDescription, dispatch_queue_t queue, dispatch_group_t group, const PlaylistSettings *settings)
{
	NSString *actionName = stepDescription[@"action"];
	if(actionName == nil)
	{
		fprintf(stderr, "Action not specified in a step.\n");
		return;
	}

	FileAction fileAction = kFileActionInvalid;
	bool isSrcDestAction = false;

	if([actionName isEqualToString:@"clone"] || [actionName isEqualToString:@"copy"])
	{
		fileAction = kFileActionClone;
		isSrcDestAction = true;
	}
	else if([actionName isEqualToString:@"move"])
	{
		fileAction = kFileActionMove;
		isSrcDestAction = true;
	}
	else if([actionName isEqualToString:@"hardlink"])
	{
		fileAction = kFileActionHardlink;
		isSrcDestAction = true;
	}
	else if([actionName isEqualToString:@"symlink"])
	{
		fileAction = kFileActionSymlink;
		isSrcDestAction = true;
	}
	else if([actionName isEqualToString:@"create"])
	{
		fileAction = kFileActionCreate;
		isSrcDestAction = false;
	}
	else if([actionName isEqualToString:@"delete"])
	{
		fileAction = kFileActionDelete;
		isSrcDestAction = false;
	}
	else
	{
		fileAction = kFileActionInvalid;
		fprintf(stderr, "Unrecognized step action: %s\n", [actionName UTF8String]);
	}
	
	if(fileAction == kFileActionInvalid)
		return;
	
	Class stringClass = [NSString class];
	Class arrayClass = [NSArray class];

	dispatch_block_t action = NULL;

	if(isSrcDestAction)
	{
		NSString *sourcePath = stepDescription[@"from"];
		NSString *destinationPath = stepDescription[@"to"];
		if([sourcePath isKindOfClass:stringClass] && [destinationPath isKindOfClass:stringClass])
		{//simple one-to-one form
			NSURL *sourceURL = nil;
			NSURL *destinationURL = nil;
			sourcePath = StringByExpandingEnvironmentVariables(sourcePath, settings->environment, settings->verbose);
			if(sourcePath != nil)
				sourceURL = [NSURL fileURLWithPath:sourcePath];
			
			destinationPath = StringByExpandingEnvironmentVariables(destinationPath, settings->environment, settings->verbose);
			if(destinationPath != nil)
				destinationURL = [NSURL fileURLWithPath:destinationPath];
			
			DispatchOneSourceDestinationAction(queue, group, fileAction, sourceURL, destinationURL, settings);
		}
		else
		{//multiple items to destintation directory form
			NSArray<NSString*> *itemPaths = stepDescription[@"items"];
			NSString *destinationDirPath = stepDescription[@"destination directory"];
			if([itemPaths isKindOfClass:arrayClass] && [destinationDirPath isKindOfClass:stringClass])
			{
				NSArray<NSURL*> *srcItemURLs = ItemPathsToURLs(itemPaths, settings);
				if(srcItemURLs != nil)
				{
					NSURL *destinationDirectoryURL = nil;
					NSString *expandedDestinationDirPath = StringByExpandingEnvironmentVariables(destinationDirPath, settings->environment, settings->verbose);
					if(expandedDestinationDirPath != nil)
						destinationDirectoryURL = [NSURL fileURLWithPath:expandedDestinationDirPath isDirectory:YES];

					NSArray<NSURL*> *destItemURLs = GetDestinationsForMultipleItems(srcItemURLs, destinationDirectoryURL, settings);
					NSUInteger destIndex = 0;
					for(NSURL *srcItemURL in srcItemURLs)
					{
						NSURL *destinationURL = [destItemURLs objectAtIndex:destIndex];
						++destIndex;
						DispatchOneSourceDestinationAction(queue, group, fileAction, srcItemURL, destinationURL, settings);
					}
				}
			}
		}
	}
	else
	{
		if(fileAction == kFileActionDelete)
		{
			NSArray<NSString*> *itemPaths = stepDescription[@"items"];
			if([itemPaths isKindOfClass:arrayClass])
			{
				for(NSString *onePath in itemPaths)
				{
					NSString *expandedPath = StringByExpandingEnvironmentVariables(onePath, settings->environment, settings->verbose);
					NSURL *oneURL = [NSURL fileURLWithPath:expandedPath];
					action = ^{
						__unused bool isOK = DeleteItem(oneURL, settings);
					};
					DispatchAction(queue, group, action);
				}
			}
			else
			{
				fprintf(stderr, "\"items\" is expected to be an array of paths\n");
			}
		}
		else if(fileAction == kFileActionCreate)
		{
			NSString *filePath = stepDescription[@"file"];
			if([filePath isKindOfClass:stringClass])
			{
				NSString *content = stepDescription[@"content"];
				if(content == nil)
					content = @""; //content is optional
				if(![content isKindOfClass:stringClass])
				{
					fprintf(stderr, "\"content\" is expected to be a string\n");
					content = @"";
				}
				
				bool expandContent = true;
				id useRawText = stepDescription[@"raw content"];
				if([useRawText isKindOfClass:[NSNumber class]])
				{
					expandContent = ![useRawText boolValue];
				}

				if(expandContent)
					content = StringByExpandingEnvironmentVariables(content, settings->environment, settings->verbose);
				
				NSString *expandedPath = StringByExpandingEnvironmentVariables(filePath, settings->environment, settings->verbose);
				NSURL *fileURL = [NSURL fileURLWithPath:expandedPath];
				action = ^{
					__unused bool isOK = CreateFile(fileURL, content, settings);
				};
				DispatchAction(queue, group, action);
			}
			else
			{
				NSString *dirPath = stepDescription[@"directory"];
				if([dirPath isKindOfClass:stringClass])
				{
					NSString *expandedDirPath = StringByExpandingEnvironmentVariables(dirPath, settings->environment, settings->verbose);
					NSURL *dirURL = [NSURL fileURLWithPath:expandedDirPath];
					action = ^{
						__unused bool isOK = CreateDirectory(dirURL, settings);
					};
					DispatchAction(queue, group, action);
				}
			}
		}
	}
}


static inline void
DispatchSteps(NSArray<NSDictionary*> *playlist, const PlaylistSettings *settings)
{
	dispatch_group_t group = NULL;
	dispatch_queue_t queue = NULL;

	if(settings->concurrent)
	{
		group = dispatch_group_create();
		queue = dispatch_queue_create("concurrent.playback", DISPATCH_QUEUE_CONCURRENT);
	}
	else
	{ //serial
		queue = dispatch_queue_create("serial.playback", DISPATCH_QUEUE_SERIAL);
	}

#if TRACE
	printf("start dispatching async tasks\n");
#endif

	Class dictionaryClass = [NSDictionary class];

	for(id oneStep in playlist)
	{
		if([oneStep isKindOfClass:dictionaryClass])
		{
			DispatchStep((NSDictionary *)oneStep, queue, group, settings);
		}
		else
		{
			fprintf(stderr, "Invalid non-dictionary step in the playlist\n");
		}
	}

#if TRACE
	printf("done dispatching async tasks\n");
#endif

	if(settings->concurrent)
	{
		dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
#if TRACE
		printf("done waiting in dispatch_group_wait()\n");
#endif
	}
	else
	{ //serial
		dispatch_sync(queue, ^{
#if TRACE
			printf("executing terminating sync task\n");
#endif
		});
	}
	

}


static struct option sLongOptions[] =
{
	{"verbose",			no_argument,		NULL, 'v'},
	{"dry-run",			no_argument,		NULL, 'n'},
	{"serial",			no_argument,		NULL, 's'},
	{"playlist-key",	required_argument,	NULL, 'k'},
	{"help",			no_argument,		NULL, 'h'},
	{NULL, 				0, 					NULL,  0 }
};

static void
DisplayHelp(void)
{
	printf(
		"\n"
		"replay -- execute a declarative script of actions, aka a playlist\n"
		"\n"
		"Usage: replay [options] <playlist_file.json|plist>\n"
		"\n"
		"Options:\n"
		"\n"
		"  -s, --serial       execute actions serially in the order specified in the playlist (slow)\n"
		"                     default behavior is to execute actions concurrently with no order guarantee (fast)\n"
		"  -k, --playlist-key KEY   declare a key in root dictionary of the playlist file for action steps array\n"
		"                     if absent, the playlist file root container is assumed to be an array of action steps\n"
		"  -n, --dry-run      show a log of actions which would be performed without running them\n"
		"  -v, --verbose      show a log of actions while they are executed\n"
		"  -h, --help         display this help\n"
		"\n"
	);

	printf(
		"Playlist format:\n"
		"\n"
		"  Playlists can be composed in plist or JSON files\n"
		"  In the usual form the root container of a plist or JSON file is a dictionary,\n"
		"  where you can put one or more playlists with unique keys.\n"
		"  A playlist is an array of action steps.\n"
		"  Each step is a dictionary with action type and parameters. See below for actions and examples.\n"
		"  If you don't specify the playlist key the root container is expected to be an array of action steps.\n"
		"  More than one playlist may be present in a root dictionary. For example you may want preparation steps\n"
		"  in one playlist to be executed by \"replay\" invocation with --serial option\n"
		"  and have another concurrent playlist with the bulk of work executed by a second \"replay\" invocation\n"
		"\n"
	);

	printf(
		"Environment variables expansion:\n"
		"\n"
		"  Environment variables in form of ${VARIABLE} are expanded in all paths\n"
		"  New file content may also contain environment variables in its body (with an option to turn off expansion)\n"
		"\n"
	);

	printf(
		"Actions and parameters:\n"
		"\n"
		"  clone       Copy file(s) from one location to another. Cloning is supported on APFS volumes\n"
		"              Source and destination for this action can be specified in 2 ways.\n"
		"              One to one:\n"
		"    from      source item path\n"
		"    to        destination item path\n"
		"              Or many items to destination directory:\n"
		"    items     array of source item paths\n"
		"    destination directory   path to output folder\n"
		"  copy        Synonym for clone. Functionally identical.\n"
		"  move        Move a file or directory\n"
		"              Source and destination for this action can be specified the same way as for \"clone\"\n"
		"  hardlink    Create a hardlink to source file\n"
		"              Source and destination for this action can be specified the same way as for \"clone\"\n"
		"  symlink     Create a symlink pointing to original file\n"
		"              Source and destination for this action can be specified the same way as for \"clone\"\n"
		"  create      Create a file or a directory\n"
      	"              you can create either a file with optional content or a directory but not both in one action step\n"
      	"    file      new file path (only for files)\n"
      	"    content   new file content string (only for files)\n"
      	"    raw content   bool value to indicate whether environment variables should be expanded or not\n"
      	"              default value is false, meaning that environment variables are expanded\n"
      	"              use true if you want to write a script with some ${VARIABLE} usage\n"
      	"    directory   new directory path. All directories leading to the deepest one are created if they don't exist\n"
		"  delete      Delete a file or directory (with its content).\n"
		"              CAUTION: There is no warning or user confirmation requested before deletion\n"
		"    items     array of item paths to delete (files or directories with their content)\n"
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
		"./replay --dry-run --playlist-key \"Shepherd Playlist\" shepherd.plist\n"
		"\n"
		"\n"
	);
}

int main(int argc, const char * argv[])
{
	PlaylistSettings settings;
	settings.environment = [[NSProcessInfo processInfo] environment];
	settings.concurrent = true;
	settings.verbose = false;
	settings.dryRun = false;

	const char *playlistKey = NULL;
	
	while(true)
	{
		int index = 0;
		int oneOption = getopt_long (argc, (char * const *)argv, "vnsk:", sLongOptions, &index);
		if (oneOption == -1) //end of options is signalled by -1
			break;
			
		switch(oneOption)
		{
			case 'v':
				settings.verbose = true;
			break;
			
			case 'n':
				settings.dryRun = true;
			break;

			case 's':
				settings.concurrent = false;
			break;
			
			case 'k':
				playlistKey = optarg;
			break;
			
			case 'h':
				DisplayHelp();
				return 0;
			break;
		}
	}
	
	const char *playlistPath = NULL;
	if (optind < argc)
	{
		playlistPath = argv[optind];
		optind++;
	}

	NSArray<NSDictionary*> *playlist = GetPlaylist(playlistPath, playlistKey);
	if(playlist == nil)
	{
		printf("Empty playlist. No steps to replay\n");
		return 0;
	}
	
	DispatchSteps(playlist, &settings);

	//TODO: propagate errors to return non-0 if something fails
	return 0;
}
