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

//a helper class to ensure atomic access to shared NSError from multiple threads

@interface AtomicError : NSObject
	@property(atomic, strong) NSError *error;
@end

@implementation AtomicError

@end

typedef struct
{
	NSDictionary<NSString *,NSString *> *environment;
	AtomicError *lastError;
	bool concurrent;
	bool verbose;
	bool dryRun;
	bool stopOnError;
	bool force;
} ReplayContext;


// this function returns nil if the string is malformed or environment variable is not found
// in both cases we treat this as a hard error and not allow executing an action with such string
// becuase it may lead to file operations in unexpected locations

static NSString *
StringByExpandingEnvironmentVariables(NSString *origString, NSDictionary<NSString *,NSString *> *environment)
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
	
	bool isMalformedOrInvalid = false;
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
					fprintf(stderr, "Referenced environment variable \"%s\" not found\n", [envVarName UTF8String]);
					isMalformedOrInvalid = true;
					break;
				}
				else
				{//add only found env variable values
					[stringChunks addObject:envValue];
				}
				chunkStart = i+1; //do not increment "i" here. for loop will do it in the next iteration
			}
			else //unterminated ${} sequence - return nil
			{
				// translate the error to 1-based index
				fprintf(stderr, "Unterminated environment variable sequence at character %lu in string \"%s\"\n", chunkStart-1, [origString UTF8String]);
				isMalformedOrInvalid = true;
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
	if(!isMalformedOrInvalid)
		expandedString = [stringChunks componentsJoinedByString:@""];

	return expandedString;
}

static NSString *
StringByExpandingEnvironmentVariablesWithErrorCheck(NSString *origString, ReplayContext *context)
{
	NSString *outStr = StringByExpandingEnvironmentVariables(origString, context->environment);
	if(outStr == nil)
	{
		NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Malformed string or missing evnironment variable" };
		NSError *operationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
		context->lastError.error = operationError;
	}
	return outStr;
}


//this function is used when the playlist key is non-null so the root container must be a dictionary
static inline NSDictionary*
LoadPlaylistRootDictionary(const char* playlistPath, ReplayContext *context)
{
	if(playlistPath == NULL)
	{
		fprintf(stderr, "Playlist file path not provided\n");
		return nil;
	}

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
			playlistDict = [NSDictionary dictionaryWithContentsOfURL:playlistURL];
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

			fprintf(stderr, "Playlist file \"%s\" cannot be opened. Error: \"%s\"\n", [[playlistURL path] UTF8String], [errorDesc UTF8String]);
		}
		else
		{
			NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Unkown or invalid playlist type" };
			context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
			fprintf(stderr, "Unkown or invalid playlist type. Only .plist and .json playlists are supported\nWith playlist key specified, the root container is expected to be a dictionary\n");
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
		fprintf(stderr, "Playlist file path not provided\n");
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
			playlistArray = [NSArray arrayWithContentsOfURL:playlistURL];
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

			fprintf(stderr, "Playlist file \"%s\" cannot be opened. Error: \"%s\"\n", [[playlistURL path] UTF8String], [errorDesc UTF8String]);
		}
		else
		{
			NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Unkown or invalid playlist type" };
			context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
			fprintf(stderr, "Unkown or invalid playlist type. Only .plist and .json playlists are supported\nWith playlist key not specified, the root container is expected to be an array.\n");
		}
	}

	return playlistArray;
}

static bool
CloneItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, NSDictionary *actionSettings)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		fprintf(stdout, "[clone]	%s	%s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String]);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;
		isSuccessful = (bool)[fileManager copyItemAtURL:(NSURL *)fromURL toURL:(NSURL *)toURL error:&operationError];

		if(!isSuccessful && context->force)
		{
			// there are actually 2 reasons why it may fail: destination file existing or parent dir not existing
			// we could test first if any of these are true or we can just blindly try brute-force both
			bool removalOK = [fileManager removeItemAtURL:toURL error:nil];
			if(!removalOK)
			{//could not remove the destination item - maybe the parent dir does not exist?
				NSURL *parentDirURL = [toURL URLByDeletingLastPathComponent];
				[fileManager createDirectoryAtURL:parentDirURL withIntermediateDirectories:YES attributes:nil error:nil]; // ignore the result, just retry
			}

			isSuccessful = (bool)[fileManager copyItemAtURL:(NSURL *)fromURL toURL:(NSURL *)toURL error:&operationError];
		}

		if(!isSuccessful)
		{
			context->lastError.error = operationError;
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
MoveItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, NSDictionary *actionSettings)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		fprintf(stdout, "[move]	%s	%s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String]);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;
		isSuccessful = (bool)[fileManager moveItemAtURL:fromURL toURL:toURL error:&operationError];

		if(!isSuccessful && context->force)
		{
			// there are actually 2 reasons why it may fail: destination file existing or parent dir not existing
			// we could test first if any of these are true or we can just blindly try brute-force both
			bool removalOK = [fileManager removeItemAtURL:toURL error:nil];
			if(!removalOK)
			{//could not remove the destination item - maybe the parent dir does not exist?
				NSURL *parentDirURL = [toURL URLByDeletingLastPathComponent];
				[fileManager createDirectoryAtURL:parentDirURL withIntermediateDirectories:YES attributes:nil error:nil]; // ignore the result, just retry
			}

			isSuccessful = (bool)[fileManager moveItemAtURL:fromURL toURL:toURL error:&operationError];
		}

		if(!isSuccessful)
		{
			context->lastError.error = operationError;
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
HardlinkItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, NSDictionary *actionSettings)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		fprintf(stdout, "[hardlink]	%s	%s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String]);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;
		isSuccessful = (bool)[fileManager linkItemAtURL:fromURL toURL:toURL error:&operationError];

		if(!isSuccessful && context->force)
		{
			// there are actually 2 reasons why it may fail: destination file existing or parent dir not existing
			// we could test first if any of these are true or we can just blindly try brute-force both
			bool removalOK = [fileManager removeItemAtURL:toURL error:nil];
			if(!removalOK)
			{//could not remove the destination item - maybe the parent dir does not exist?
				NSURL *parentDirURL = [toURL URLByDeletingLastPathComponent];
				[fileManager createDirectoryAtURL:parentDirURL withIntermediateDirectories:YES attributes:nil error:nil]; // ignore the result, just retry
			}

			isSuccessful = (bool)[fileManager linkItemAtURL:fromURL toURL:toURL error:&operationError];
		}

		if(!isSuccessful)
		{
			context->lastError.error = operationError;
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
SymlinkItem(NSURL *fromURL, NSURL *linkURL, ReplayContext *context, NSDictionary *actionSettings)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		fprintf(stdout, "[symlink]	%s	%s\n", [[fromURL path] UTF8String], [[linkURL path] UTF8String]);
	}
	
	bool force = context->force;
	bool isSuccessful = context->dryRun;

	if(!context->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;

		NSNumber *validateSource = actionSettings[@"validate"];
		bool validateSymlinkSource = true;
		if([validateSource isKindOfClass:[NSNumber class]])
		{
			validateSymlinkSource = [validateSource boolValue];
		}

		if(validateSymlinkSource && ![fileManager fileExistsAtPath:[fromURL path]])
		{
			NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Strict validation: attempt to create a symlink to nonexistent item" };
			operationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
			isSuccessful = false;
			force = false;
		}
		else
		{
			isSuccessful = (bool)[fileManager createSymbolicLinkAtURL:linkURL withDestinationURL:(NSURL *)fromURL error:&operationError];
		}

		if(!isSuccessful && force)
		{
			// there are actually 2 reasons why it may fail: destination file existing or parent dir not existing
			// we could test first if any of these are true or we can just blindly try brute-force both
			bool removalOK = [fileManager removeItemAtURL:linkURL error:nil];
			if(!removalOK)
			{//could not remove the destination item - maybe the parent dir does not exist?
				NSURL *parentDirURL = [linkURL URLByDeletingLastPathComponent];
				[fileManager createDirectoryAtURL:parentDirURL withIntermediateDirectories:YES attributes:nil error:nil]; // ignore the result, just retry
			}
			isSuccessful = (bool)[fileManager createSymbolicLinkAtURL:linkURL withDestinationURL:(NSURL *)fromURL error:&operationError];
		}

		if(!isSuccessful)
		{
			context->lastError.error = operationError;
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
CreateFile(NSURL *itemURL, NSString *content, ReplayContext *context, NSDictionary *actionSettings)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		//TODO: escape newlines for multiline text so it will be displayed in one line
		fprintf(stdout, "[create]	%s	%s\n", [[itemURL path] UTF8String], [content UTF8String]);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		NSError *operationError = nil;
		isSuccessful = [content writeToURL:itemURL atomically:NO encoding:NSUTF8StringEncoding error:&operationError];
		
		if(!isSuccessful && context->force)
		{
			// there are actually 2 reasons why it may fail: destination file existing or parent dir not existing
			// we could test first if any of these are true or we can just blindly try brute-force both
			NSFileManager *fileManager = [NSFileManager defaultManager];
			bool removalOK = [fileManager removeItemAtURL:itemURL error:nil];
			if(!removalOK)
			{//could not remove the destination item - maybe the parent dir does not exist?
				NSURL *parentDirURL = [itemURL URLByDeletingLastPathComponent];
				[fileManager createDirectoryAtURL:parentDirURL withIntermediateDirectories:YES attributes:nil error:nil]; // ignore the result, just retry
			}

			isSuccessful = [content writeToURL:itemURL atomically:NO encoding:NSUTF8StringEncoding error:&operationError];
		}

		if(!isSuccessful)
		{
			context->lastError.error = operationError;
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
CreateDirectory(NSURL *itemURL, ReplayContext *context, NSDictionary *actionSettings)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		fprintf(stdout, "[create]	%s\n", [[itemURL path] UTF8String]);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;
		isSuccessful = [fileManager createDirectoryAtURL:itemURL withIntermediateDirectories:YES attributes:nil error:&operationError];

		// this call is not supposed to fail for existing directories if you use withIntermediateDirectories:YES
		// so the behavior should be the same as mkdir -p
		
		if(!isSuccessful)
		{
			context->lastError.error = operationError;
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
DeleteItem(NSURL *itemURL, ReplayContext *context, NSDictionary *actionSettings)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		fprintf(stdout, "[delete]	%s\n", [[itemURL path] UTF8String]);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;
		isSuccessful = (bool)[fileManager removeItemAtURL:itemURL error:&operationError];
		if(!isSuccessful)
		{
			if(![fileManager fileExistsAtPath:[itemURL path]])
				return true; //do not treat it as an error if the object we tried to delete does not exist
		
			context->lastError.error = operationError;
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
ItemPathsToURLs(NSArray<NSString*> *itemPaths, ReplayContext *context)
{
	NSUInteger fileCount = [itemPaths count];
	NSMutableArray *itemURLs = [NSMutableArray arrayWithCapacity:fileCount];
	
	for(NSString *itemPath in itemPaths)
	{
		NSString *expandedFileName = StringByExpandingEnvironmentVariablesWithErrorCheck(itemPath, context);
		if(expandedFileName != nil)
		{
			NSURL *itemURL = [NSURL fileURLWithPath:expandedFileName];
			[itemURLs addObject:itemURL];
		}
		else if(context->stopOnError)
		{
			return nil;
		}
	}

	return itemURLs;
}

//when an operation is specified as a list of source items and destination dir
//create explicit list of destination URLs corresponding to source file names
//if more than one source file happens to have the same name, items will be overwritten

static NSArray<NSURL*> *
GetDestinationsForMultipleItems(NSArray<NSURL*> *sourceItemURLs, NSURL *destinationDirectoryURL, ReplayContext *context)
{
	if((sourceItemURLs == nil) || (destinationDirectoryURL == nil))
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
DispatchOneSourceDestinationAction(dispatch_queue_t queue, dispatch_group_t group, FileAction fileAction, NSURL *sourceURL, NSURL *destinationURL, ReplayContext *context, NSDictionary *actionSettings)
{
	if((sourceURL == nil) || (destinationURL == nil))
		return;

	dispatch_block_t action = NULL;
	switch(fileAction)
	{
		case kFileActionClone:
		{
			action = ^{
				__unused bool isOK = CloneItem(sourceURL, destinationURL, context, actionSettings);
			};
		}
		break;

		case kFileActionMove:
		{
			action = ^{
				__unused bool isOK = MoveItem(sourceURL, destinationURL, context, actionSettings);
			};
		}
		break;
		
		case kFileActionHardlink:
		{
			action = ^{
				__unused bool isOK = HardlinkItem(sourceURL, destinationURL, context, actionSettings);
			};
		}
		break;

		case kFileActionSymlink:
		{
			action = ^{
				__unused bool isOK = SymlinkItem(sourceURL, destinationURL, context, actionSettings);
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
DispatchStep(NSDictionary *stepDescription, dispatch_queue_t queue, dispatch_group_t group, ReplayContext *context)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return;

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
			sourcePath = StringByExpandingEnvironmentVariablesWithErrorCheck(sourcePath, context);
			if(sourcePath != nil)
				sourceURL = [NSURL fileURLWithPath:sourcePath];
			
			destinationPath = StringByExpandingEnvironmentVariablesWithErrorCheck(destinationPath, context);
			if(destinationPath != nil)
				destinationURL = [NSURL fileURLWithPath:destinationPath];
			
			// handles nil sourceURL or destinationURL by skipping action
			DispatchOneSourceDestinationAction(queue, group, fileAction, sourceURL, destinationURL, context, stepDescription);
		}
		else
		{//multiple items to destintation directory form
			NSArray<NSString*> *itemPaths = stepDescription[@"items"];
			NSString *destinationDirPath = stepDescription[@"destination directory"];
			if([itemPaths isKindOfClass:arrayClass] && [destinationDirPath isKindOfClass:stringClass])
			{
				NSArray<NSURL*> *srcItemURLs = ItemPathsToURLs(itemPaths, context);
				if(srcItemURLs != nil)
				{
					NSURL *destinationDirectoryURL = nil;
					NSString *expandedDestinationDirPath = StringByExpandingEnvironmentVariablesWithErrorCheck(destinationDirPath, context);
					if(expandedDestinationDirPath != nil)
						destinationDirectoryURL = [NSURL fileURLWithPath:expandedDestinationDirPath isDirectory:YES];
					
					//handles nil destinationDirectoryURL by returning empty array
					NSArray<NSURL*> *destItemURLs = GetDestinationsForMultipleItems(srcItemURLs, destinationDirectoryURL, context);
					NSUInteger destIndex = 0;
					for(NSURL *srcItemURL in srcItemURLs)
					{
						NSURL *destinationURL = [destItemURLs objectAtIndex:destIndex];
						++destIndex;
						DispatchOneSourceDestinationAction(queue, group, fileAction, srcItemURL, destinationURL, context, stepDescription);
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
					NSString *expandedPath = StringByExpandingEnvironmentVariablesWithErrorCheck(onePath, context);
					if(expandedPath != nil)
					{
						NSURL *oneURL = [NSURL fileURLWithPath:expandedPath];
						action = ^{
							__unused bool isOK = DeleteItem(oneURL, context, stepDescription);
						};
						DispatchAction(queue, group, action);
					}
					else if(context->stopOnError)
					{ // one invalid path stops all actions
						break;
					}
				}
			}
			else
			{
				fprintf(stderr, "\"items\" is expected to be an array of paths\n");
				NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Unexpected items type" };
				NSError *operationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
				context->lastError.error = operationError;
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
					content = StringByExpandingEnvironmentVariablesWithErrorCheck(content, context);
				
				NSString *expandedPath = StringByExpandingEnvironmentVariablesWithErrorCheck(filePath, context);
				
				// content is nil only if string is malformed or missing environment variable
				// otherwise the string may be empty but non-nil
				if((content != nil) && (expandedPath != nil))
				{
					NSURL *fileURL = [NSURL fileURLWithPath:expandedPath];
					action = ^{
						__unused bool isOK = CreateFile(fileURL, content, context, stepDescription);
					};
					DispatchAction(queue, group, action);
				}
			}
			else
			{
				NSString *dirPath = stepDescription[@"directory"];
				if([dirPath isKindOfClass:stringClass])
				{
					NSString *expandedDirPath = StringByExpandingEnvironmentVariablesWithErrorCheck(dirPath, context);
					if(expandedDirPath != nil)
					{
						NSURL *dirURL = [NSURL fileURLWithPath:expandedDirPath];
						action = ^{
							__unused bool isOK = CreateDirectory(dirURL, context, stepDescription);
						};
						DispatchAction(queue, group, action);
					}
				}
				else
				{
					fprintf(stderr, "\"create\" action must specify \"file\" or \"directory\" \n");
					NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Invalid create action specification" };
					NSError *operationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
					context->lastError.error = operationError;
				}
			}
		}
	}
}


static inline void
DispatchSteps(NSArray<NSDictionary*> *playlist, ReplayContext *context)
{
	dispatch_group_t group = NULL;
	dispatch_queue_t queue = NULL;

	if(context->concurrent)
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
			DispatchStep((NSDictionary *)oneStep, queue, group, context);
		}
		else
		{
			fprintf(stderr, "Invalid non-dictionary step in the playlist\n");
		}
	}

#if TRACE
	printf("done dispatching async tasks\n");
#endif

	if(context->concurrent)
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
	{"stop-on-error",   no_argument,		NULL, 'e'},
	{"force",           no_argument,		NULL, 'f'},
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
		"                     the key may be specified multiple times to execute more than one playlist in the file\n"
		"  -e, --stop-on-error   stop executing the remaining playlist actions on first error\n"
		"  -f, --force        if the file operation fails, delete destination and try again\n"
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
		"  Missing environment variables or malformed text is considered an error and the action will not be executed\n"
		"  It is easy to make a mistake and allowing evironment variables resolved to empty would result in invalid paths,\n"
		"  potentially leading to destructive file operations\n"
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
      	"    validate   bool value to indicate whether to check for the existence of source file. Default is true\n"
      	"              it is usually a mistake if you try to create a symlink to nonexistent file\n"
      	"              that is why \"validate\" is true by default but it is possible to create a dangling symlink\n"
      	"              if you know what you are doing and really want that behavior, set \"validate\" to false\n"
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
	ReplayContext context;
	context.environment = [[NSProcessInfo processInfo] environment];
	context.lastError = [AtomicError new];
	context.concurrent = true;
	context.verbose = false;
	context.dryRun = false;
	context.stopOnError = false;
	context.force = false;

	NSMutableArray *playlistKeys = [NSMutableArray new];

	while(true)
	{
		int index = 0;
		int oneOption = getopt_long (argc, (char * const *)argv, "vnsk:efh", sLongOptions, &index);
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
			
			case 'h':
				DisplayHelp();
				return EXIT_SUCCESS;
			break;
		}
	}
	
	const char *playlistPath = NULL;
	if (optind < argc)
	{
		playlistPath = argv[optind];
		optind++;
	}

	if ([playlistKeys count] > 0)
	{
		NSDictionary* playlistRootDict = LoadPlaylistRootDictionary(playlistPath, &context);
		if(playlistRootDict == nil)
		{
			printf("Invalid or empty playlist \"%s\". No steps to replay\n", playlistPath);
			return EXIT_SUCCESS;
		}

		for(NSString *oneKey in playlistKeys)
		{
			NSArray<NSDictionary*> *playlist = playlistRootDict[oneKey];
			if(playlist != nil)
			{
				DispatchSteps(playlist, &context);
			}
			else
			{
				printf("Invalid or empty playlist for key \"%s\". No steps to replay\n", [oneKey UTF8String]);
				if(context.stopOnError)
				{
					break;
				}
			}
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
		DispatchSteps(playlist, &context);
	}

	if(context.lastError.error != nil)
		return EXIT_FAILURE;

	return EXIT_SUCCESS;
}
