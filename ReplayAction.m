#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "StringAndPath.h"
#import "OutputSerializer.h"

//a helper class to ensure atomic access to shared NSError from multiple threads
@implementation AtomicError

@end

static inline void PrintToStdOut(ReplayContext *context, NSString *string, NSInteger actionIndex)
{
	if(context->orderedOutput)
	{
		assert(context->outputSerializer != nil);
		assert(actionIndex >=0);
	}

	PrintSerializedString(context->outputSerializer, string, context->orderedOutput ? actionIndex : -1);
}

static inline void PrintStringsToStdOut(ReplayContext *context, NSArray<NSString *> *array, NSInteger actionIndex)
{
	if(context->orderedOutput)
	{
		assert(context->outputSerializer != nil);
		assert(actionIndex >=0);
	}

	PrintSerializedStrings(context->outputSerializer, array, context->orderedOutput ? actionIndex : -1);
}


static inline void ActionWithNoOutput(ReplayContext *context, NSInteger actionIndex)
{
	if(context->orderedOutput)
	{
		assert(context->outputSerializer != nil);
		assert(actionIndex >=0);
		PrintSerializedString(context->outputSerializer, nil, actionIndex);
	}
}

static inline Action
ActionFromName(NSString *actionName, bool *isSrcDestActionPtr)
{
	if(actionName == nil)
	{
		fprintf(stderr, "error: action not specified in a step.\n");
		return kActionInvalid;
	}

	Action replayAction = kActionInvalid;
	bool isSrcDestAction = false;

	if([actionName isEqualToString:@"clone"] || [actionName isEqualToString:@"copy"])
	{
		replayAction = kFileActionClone;
		isSrcDestAction = true;
	}
	else if([actionName isEqualToString:@"move"])
	{
		replayAction = kFileActionMove;
		isSrcDestAction = true;
	}
	else if([actionName isEqualToString:@"hardlink"])
	{
		replayAction = kFileActionHardlink;
		isSrcDestAction = true;
	}
	else if([actionName isEqualToString:@"symlink"])
	{
		replayAction = kFileActionSymlink;
		isSrcDestAction = true;
	}
	else if([actionName isEqualToString:@"create"])
	{
		replayAction = kFileActionCreate;
		isSrcDestAction = false;
	}
	else if([actionName isEqualToString:@"delete"])
	{
		replayAction = kFileActionDelete;
		isSrcDestAction = false;
	}
	else if([actionName isEqualToString:@"execute"])
	{
		replayAction = kActionExecuteTool;
		isSrcDestAction = false;
	}
	else if([actionName isEqualToString:@"echo"])
	{
		replayAction = kActionEcho;
		isSrcDestAction = false;
	}
	else
	{
		replayAction = kActionInvalid;
		fprintf(stderr, "error: unrecognized step action: %s\n", [actionName UTF8String]);
	}

	*isSrcDestActionPtr = isSrcDestAction;
	return replayAction;
}


static inline dispatch_block_t
CreateSourceDestinationAction(Action replayAction, NSURL *sourceURL, NSURL *destinationURL, ReplayContext *context, NSDictionary *actionSettings, NSInteger actionIndex)
{
	if((sourceURL == nil) || (destinationURL == nil))
		return nil;

	dispatch_block_t action = NULL;
	switch(replayAction)
	{
		case kFileActionClone:
		{
            action = ^{ @autoreleasepool {
				ActionContext localContext = { .settings = actionSettings, .index = actionIndex };
				__unused bool isOK = CloneItem(sourceURL, destinationURL, context, &localContext);
            }};
		}
		break;

		case kFileActionMove:
		{
            action = ^{ @autoreleasepool {
				ActionContext localContext = { .settings = actionSettings, .index = actionIndex };
				__unused bool isOK = MoveItem(sourceURL, destinationURL, context, &localContext);
            }};
		}
		break;
		
		case kFileActionHardlink:
		{
            action = ^{ @autoreleasepool {
				ActionContext localContext = { .settings = actionSettings, .index = actionIndex };
				__unused bool isOK = HardlinkItem(sourceURL, destinationURL, context, &localContext);
            }};
		}
		break;

		case kFileActionSymlink:
		{
            action = ^{ @autoreleasepool {
				ActionContext localContext = { .settings = actionSettings, .index = actionIndex };
				__unused bool isOK = SymlinkItem(sourceURL, destinationURL, context, &localContext);
            }};
		}
		break;
		
		default:
		{
		}
		break;
	}
	return action;
}

static inline NSArray<NSString*> *
GetExpandedPathsFromRawPaths(NSArray<NSString*> *rawPaths, ReplayContext *context)
{
	if([rawPaths isKindOfClass:[NSArray class]])
	{
		NSMutableArray<NSString*> *expandedPaths = [NSMutableArray arrayWithCapacity:[rawPaths count]];
		for(NSString *onePath in rawPaths)
		{
			NSString *expandedPath = StringByExpandingEnvironmentVariablesWithErrorCheck(onePath, context);
			if(expandedPath != nil)
			{
				NSURL *oneURL = [NSURL fileURLWithPath:expandedPath];
				[expandedPaths addObject:oneURL.absoluteURL.path];
			}
		}
		return expandedPaths;
	}
	return nil;
}

static inline
NSArray<NSString*> *PathArrayFromFileURL(NSURL *inURL)
{
	if(inURL != nil)
	{
		NSString *path = inURL.absoluteURL.path;
		if(path != nil)
			return @[path];
	}
	return nil;
}

// this function resolves each step and calls provided actionHandler
// one or more times for each action in the step
// one step may have multiple actions like copying a list of files to one directory
void
HandleActionStep(NSDictionary *stepDescription, ReplayContext *context, action_handler_t actionHandler)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return;

 @autoreleasepool {
	bool isSrcDestAction = false;
	Action replayAction = ActionFromName(stepDescription[@"action"], &isSrcDestAction);

	if(replayAction == kActionInvalid)
		return;
	
	Class stringClass = [NSString class];
	Class arrayClass = [NSArray class];

	dispatch_block_t action = NULL;
	NSArray<NSString*> *inputs = nil;
	NSArray<NSString*> *exclusiveInputs = nil;
	NSArray<NSString*> *outputs = nil;

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
			NSInteger actionIndex = ++(context->actionCounter);
			action = CreateSourceDestinationAction(replayAction, sourceURL, destinationURL, context, stepDescription, actionIndex);
			
			if(context->concurrent)
			{
				if(replayAction == kFileActionMove)
					exclusiveInputs = PathArrayFromFileURL(sourceURL);
				else
					inputs = PathArrayFromFileURL(sourceURL);
				outputs = PathArrayFromFileURL(destinationURL);
			}
			actionHandler(action, inputs, exclusiveInputs, outputs);
		}
		else
		{//multiple items to destination directory form
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
						NSInteger actionIndex = ++(context->actionCounter);
						action = CreateSourceDestinationAction(replayAction, srcItemURL, destinationURL, context, stepDescription, actionIndex);
						
						if(context->concurrent)
						{
							if(replayAction == kFileActionMove)
								exclusiveInputs = PathArrayFromFileURL(srcItemURL);
							else
								inputs = PathArrayFromFileURL(srcItemURL);
							outputs = PathArrayFromFileURL(destinationURL);
						}
						actionHandler(action, inputs, exclusiveInputs, outputs);
					}
				}
			}
		}
	}
	else
	{
		if(replayAction == kFileActionDelete)
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
						NSInteger actionIndex = ++(context->actionCounter);
                        action = ^{ @autoreleasepool {
							ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
							__unused bool isOK = DeleteItem(oneURL, context, &actionContext);
						
                        }};
						
						if(context->concurrent)
						{
							exclusiveInputs = PathArrayFromFileURL(oneURL);
						}
						actionHandler(action,  nil, exclusiveInputs, nil);
					}
					else if(context->stopOnError)
					{ // one invalid path stops all actions
						break;
					}
				}
			}
			else
			{
				fprintf(stderr, "error: \"items\" is expected to be an array of paths\n");
				NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Unexpected items type" };
				NSError *operationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
				context->lastError.error = operationError;
			}
		}
		else if(replayAction == kFileActionCreate)
		{
			NSString *filePath = stepDescription[@"file"];
			if([filePath isKindOfClass:stringClass])
			{
				NSString *content = stepDescription[@"content"];
				if(content == nil)
					content = @""; //content is optional
				if(![content isKindOfClass:stringClass])
				{
					fprintf(stderr, "error: \"content\" is expected to be a string\n");
					content = @"";
				}
				
				bool expandContent = true;
				id useRawText = stepDescription[@"raw"];
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
					NSInteger actionIndex = ++(context->actionCounter);
                    action = ^{ @autoreleasepool {
						ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
						__unused bool isOK = CreateFile(fileURL, content, context, &actionContext);
                    }};
					
					if(context->concurrent)
					{
						outputs = PathArrayFromFileURL(fileURL);
					}
					actionHandler(action, nil, nil, outputs);
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
						NSInteger actionIndex = ++(context->actionCounter);
                        action = ^{ @autoreleasepool {
							ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
							__unused bool isOK = CreateDirectory(dirURL, context, &actionContext);
                        }};
						
						if(context->concurrent)
						{
							outputs = PathArrayFromFileURL(dirURL);
						}
						actionHandler(action, nil, nil, outputs);
					}
				}
				else
				{
					fprintf(stderr, "error: \"create\" action must specify \"file\" or \"directory\" \n");
					NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Invalid create action specification" };
					NSError *operationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
					context->lastError.error = operationError;
				}
			}
		}
		else if(replayAction == kActionExecuteTool)
		{
			NSString *toolPath = stepDescription[@"tool"];
			if([toolPath isKindOfClass:stringClass])
			{
				NSArray<NSString*> *arguments = stepDescription[@"arguments"];
				if((arguments != nil) && ![arguments isKindOfClass:arrayClass])
				{
					fprintf(stderr, "error: \"execute\" action must specify \"arguments\" as a string array\n");
					NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Invalid execute action specification" };
					NSError *operationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
					context->lastError.error = operationError;
				}
				else
				{
					NSString *expandedToolPath = StringByExpandingEnvironmentVariablesWithErrorCheck(toolPath, context);
					if(expandedToolPath != nil)
					{
						bool argsOK = true;
						NSMutableArray *expandedArgs = [NSMutableArray arrayWithCapacity:[arguments count]];
						for(NSString *oneArg in arguments)
						{
							NSString *expandedArg = StringByExpandingEnvironmentVariablesWithErrorCheck(oneArg, context);
							if(expandedArg != nil)
							{
								[expandedArgs addObject:expandedArg];
							}
							else if(context->stopOnError)
							{ // one invalid string expansion stops all actions
								argsOK = false;
								break;
							}
						}

						if(argsOK)
						{
							NSInteger actionIndex = ++(context->actionCounter);
							action = ^{ @autoreleasepool {
                                    ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
                                    __unused bool isOK = ExcecuteTool(expandedToolPath, expandedArgs, context, &actionContext);
                            }};
							
							// [execute] action is expected to print two strings:
							// - verbose action description (or null string if not verbose)
							// - stdout from child tool (or null string if stdout is suppressed)
							// so we need to increase the counter second time
							++(context->actionCounter);

							if(context->concurrent)
							{
								inputs = GetExpandedPathsFromRawPaths(stepDescription[@"inputs"], context);
								exclusiveInputs = GetExpandedPathsFromRawPaths(stepDescription[@"exclusive inputs"], context);
								outputs = GetExpandedPathsFromRawPaths(stepDescription[@"outputs"], context);
							}

							actionHandler(action, inputs, exclusiveInputs, outputs);
						}
					}
				}
			}
			else
			{
				fprintf(stderr, "error: \"execute\" action must specify \"tool\" value with path to executable\n");
				NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Invalid execute action specification" };
				NSError *operationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
				context->lastError.error = operationError;
			}
		}
		else if(replayAction == kActionEcho)
		{
			NSString *text = stepDescription[@"text"];

			if(text == nil)
				text = @"";

			if(![text isKindOfClass:stringClass])
			{
				fprintf(stderr, "error: \"text\" is expected to be a string\n");
				text = @"";
			}
			
			bool expandText = true;
			id useRawText = stepDescription[@"raw"];
			if([useRawText isKindOfClass:[NSNumber class]])
			{
				expandText = ![useRawText boolValue];
			}

			if(expandText)
				text = StringByExpandingEnvironmentVariablesWithErrorCheck(text, context);

			// text is nil only if string is malformed or missing environment variable
			// otherwise the string may be empty but non-nil
			if(text != nil)
			{
				NSInteger actionIndex = ++(context->actionCounter);
				action = ^{ @autoreleasepool {
					ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
					__unused bool isOK = Echo(text, context, &actionContext);
				}};
				
				// [echo] action is expected to print two strings:
				// - verbose action description (or null string if not verbose)
				// - actual text printed to stdout
				// so we need to increase the counter second time
				++(context->actionCounter);

				actionHandler(action, nil, nil, outputs);
			}
		}
	}
 } //autoreleasepool
}


bool
CloneItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[clone]	%@	%@\n", [fromURL path], [toURL path]];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
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
			fprintf(stderr, "error: failed to clone from \"%s\" to \"%s\". Error: %s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

bool
MoveItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[move]	%@	%@\n", [fromURL path], [toURL path]];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
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
			fprintf(stderr, "error: failed to move from \"%s\" to \"%s\". Error: %s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

bool
HardlinkItem(NSURL *fromURL, NSURL *toURL, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[hardlink]	%@	%@\n", [fromURL path], [toURL path] ];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
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
			fprintf(stderr, "error: failed to create a hardlink from \"%s\" to \"%s\". Error: %s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

bool
SymlinkItem(NSURL *fromURL, NSURL *linkURL, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	NSNumber *validateSource = actionContext->settings[@"validate"];
	bool validateSymlinkSource = true;
	if([validateSource isKindOfClass:[NSNumber class]])
	{
		validateSymlinkSource = [validateSource boolValue];
	}

	if(context->verbose || context->dryRun)
	{
		NSString *settingsStr = @"";
		if(validateSource != nil) //explicitly set
		{
			settingsStr = validateSymlinkSource ? @" validate=true" : @" validate=false";
		}
		
		NSString *stdoutStr = [NSString stringWithFormat:@"[symlink%@]	%@	%@\n", settingsStr, [fromURL path], [linkURL path]];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}
	
	bool force = context->force;
	bool isSuccessful = context->dryRun;

	if(!context->dryRun)
	{
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSError *operationError = nil;

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
			fprintf(stderr, "error: failed to create a symlink at \"%s\" referring to \"%s\". Error: %s\n", [[linkURL path] UTF8String], [[fromURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

bool
CreateFile(NSURL *itemURL, NSString *content, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		id useRawText = actionContext->settings[@"raw"];
		NSString *settingsStr = @"";
		if([useRawText isKindOfClass:[NSNumber class]])
		{
			bool rawContent = [useRawText boolValue];
			settingsStr = rawContent ? @" raw=true" : @" raw=false";
		}

		//TODO: escape newlines for multiline text so it will be displayed in one line
		NSString *stdoutStr = [NSString stringWithFormat:@"[create file%@]	%@	%@\n", settingsStr, [itemURL path], content];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
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
			fprintf(stderr, "error: failed to create file \"%s\". Error: %s\n", [[itemURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

bool
CreateDirectory(NSURL *itemURL, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[create directory]	%@\n", [itemURL path]];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
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
			fprintf(stderr, "error: failed to create directory \"%s\". Error: %s\n", [[itemURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

bool
DeleteItem(NSURL *itemURL, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[delete]	%@\n", [itemURL path] ];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
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
			fprintf(stderr, "error: failed to delete \"%s\". Error: %s\n", [[itemURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

bool
ExcecuteTool(NSString *toolPath, NSArray<NSString*> *arguments, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	NSNumber *useStdOutNum = actionContext->settings[@"stdout"];
	bool useStdOut = true;
	if([useStdOutNum isKindOfClass:[NSNumber class]])
		useStdOut = [useStdOutNum boolValue];

	if(context->verbose || context->dryRun)
	{
		NSString *settingsStr = @"";
		if(useStdOutNum != nil) //if the setting was explicitly specified
		{
			settingsStr = useStdOut ? @" stdout=true" : @" stdout=false";
		}
		NSString *allArgsStr = [arguments componentsJoinedByString:@"\t"];
		NSString *stdoutStr = [NSString stringWithFormat:@"[execute%@]	%@	%@\n", settingsStr, toolPath, allArgsStr];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}
	
	// tool execution is expected to print two strings to stdout
	// track if the second print happened, else inform output serializer of no output
	actionContext->index++;
	bool secondStringPrinted = false;
	
	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		NSTask *task = [[NSTask alloc] init];
		[task setLaunchPath:toolPath];
		[task setArguments:arguments];

		[task setTerminationHandler: ^(NSTask *task) {
			int toolStatus = [task terminationStatus];
			if(toolStatus != EXIT_SUCCESS)
			{
				NSString *toolErrorDescription = [NSString stringWithFormat:@"%@ returned error %d", toolPath, toolStatus];
				NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: toolErrorDescription };
				NSError *taskError = [NSError errorWithDomain:NSPOSIXErrorDomain code:toolStatus userInfo:userInfo];
				context->lastError.error = taskError;
				fprintf(stderr, "error: failed to execute \"%s\". Error: %d\n", [toolPath UTF8String], toolStatus);
			}
		}];

		NSPipe *stdOutPipe = [NSPipe pipe];
		[task setStandardOutput:stdOutPipe];
		NSPipe *stdInPipe = [NSPipe pipe];
		[task setStandardInput:stdInPipe];

		NSFileHandle *stdOutFileHandle = [stdOutPipe fileHandleForReading];

		NSError *operationError = nil;
		isSuccessful = (bool)[task launchAndReturnError:&operationError];
		if(isSuccessful)
		{
			NSData *stdOutData = [stdOutFileHandle readDataToEndOfFileAndReturnError:&operationError];
			if(stdOutData != nil)
			{
				if(useStdOut)
				{
					//since we captured stdout and waited on it, now replay it to stdout
					//because it was synchronous, all output will be printed at once after the tool finished
					NSString *stdoutStr = [[NSString alloc] initWithData:stdOutData encoding:NSUTF8StringEncoding];
					PrintToStdOut(context, stdoutStr, actionContext->index);
					secondStringPrinted = true;
				}
			}
			else
			{
				isSuccessful = false;
			}
		}
		
		if (!isSuccessful)
		{
			context->lastError.error = operationError;
			NSString *errorDesc = [operationError localizedDescription];
			if(errorDesc == nil)
			{
				errorDesc = [operationError localizedFailureReason];
			}
			fprintf(stderr, "error: failed to execute \"%s\". Error: %s\n", [toolPath UTF8String], [errorDesc UTF8String] );
		}
	}
	
	if(!secondStringPrinted)
	{
		ActionWithNoOutput(context, actionContext->index);
	}
	
	return isSuccessful;
}



bool
Echo(NSString *text, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	bool addNewline = true;
	id newlineVal = actionContext->settings[@"newline"];
	if([newlineVal isKindOfClass:[NSNumber class]])
	{
		addNewline = [newlineVal boolValue];
	}

	if(text == nil)
		text = @"";

	if(context->verbose || context->dryRun)
	{
		id useRawText = actionContext->settings[@"raw"];
		NSString *rawSetting = @"";
		if([useRawText isKindOfClass:[NSNumber class]])
		{
			bool rawContent = [useRawText boolValue];
			rawSetting = rawContent ? @" raw=true" : @" raw=false";
		}

		NSString *newlineSetting = @"";
		if(newlineVal != nil) // only if explicitly set
		{
			newlineSetting = addNewline ? @" newline=true" : @" newline=false";
		}

		//TODO: escape newlines for multiline text so it will be displayed in one line
		NSString *stdoutStr = [NSString stringWithFormat:@"[echo%@%@]	%@\n", rawSetting, newlineSetting, text];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	// echo is expected to print two strings to stdout (verbose status and actual string)
	actionContext->index++;

	if(!context->dryRun)
	{
		if(addNewline)
		{
			NSArray <NSString *> *array = @[text, @"\n"];
			PrintStringsToStdOut(context, array, actionContext->index);
		}
		else
		{
			PrintToStdOut(context, text, actionContext->index);
		}
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	return true;
}

#pragma mark -

static inline void
AddOptionsToActionDescription(NSMutableDictionary *actionDescription, NSArray<NSString *> *actionAndOptionsArray)
{
	NSUInteger itemCount = actionAndOptionsArray.count;
	if(itemCount < 2)
		return; //no options

	//skipping the first word (action), examine if optional settings contain key=value
	for(NSUInteger i = 1; i < itemCount; i++)
	{
		NSString *oneOption = actionAndOptionsArray[i];
		if([oneOption containsString:@"="])
		{
			NSArray<NSString*> *keyValuesArray = [oneOption componentsSeparatedByString:@"="];
			if(keyValuesArray.count == 2)
			{
				NSString *keyStr = keyValuesArray[0];
				NSString *valStr = keyValuesArray[1];
				NSDecimalNumber *num = nil;
				if([valStr compare:@"true" options:NSCaseInsensitiveSearch] == NSOrderedSame)
				{
					actionDescription[keyStr] = @YES;
				}
				else if([valStr compare:@"false" options:NSCaseInsensitiveSearch] == NSOrderedSame)
				{
					actionDescription[keyStr] = @NO;
				}
				else if((num = [NSDecimalNumber decimalNumberWithString:valStr]) != nil)
				{//it is a number
					actionDescription[keyStr] = num;
				}
				else
				{//fall back to string
					actionDescription[keyStr] = valStr;
				}
			}
			else
			{
				fprintf(stderr, "warning: invalid option: %s\n", [oneOption UTF8String]);
			}
		}
	}
}

// The format of streamed/piped actions is one action per line, as follows:
// - ignore whitespace characters at the beginning of the line, if any
// - action and options come first in square brackets, e.g.: [clone], [move], [delete], [create file] [create directory]
// - the first character following the closing square bracket ']' is used as a field delimiter for the parameters to the action
// - variable length parameters are following, separated by the same field separator, specific to given actions

// Param interpretation per action
// (examples use "tab" as a separator)
// 1. [clone], [move], [hardlink], [symlink] allows only simple from-to specification,
// with first param interpretted as "from" and second as "to" e.g.:
// [clone]	/path/to/src/file.txt	/path/to/dest/file.txt
// 2. [delete] is followed by one or many paths to items, e.g.:
// [delete]	/path/to/delete/file1.txt	/path/to/delete/file2.txt
// 3. [create] has 2 variants: [create file] and [create directory].
// If "file" or "directory" option is not specified, it falls back to "file"
// A. [create file] requires path followed by optional content, e.g.:
// [create file]	/path/to/create/file.txt	Created by replay!
// B. [create directory] requires just a single path, e.g.:
// [create directory]	/path/to/create/directory
// 4. [execute] requires tool path and may have optional parameters separated with the same delimiter (not space delimited!), e.g.:
// [execute]	/bin/echo	Hello from replay!
// In the following example uses a different separator: "+" to explicitly show delimited parameters:
// [execute]+/bin/sh+-c+/bin/ls ${HOME} | /usr/bin/grep ".txt"

NSDictionary * ActionDescriptionFromLine(const char *line, ssize_t linelen)
{
	//skip all whitespace or any control characters at the beginning of the line
	while((linelen > 0) && (*line <= 0x20))
	{
		line++;
		linelen--;
	}
	
	//if the newline char is at the end, as it should be, strip it
	if((linelen > 0) && (line[linelen-1] == '\n'))
	{
		linelen--;
	}
	
	if((linelen > 0) && (*line == '['))
	{
		line++;
		linelen--;
	}
	else
	{
		return nil;
	}
	
	const char *actionAndOptions = line;
	size_t actionAndOptionsLen = 0;
	while((linelen > 0) && *line != ']')
	{
		line++;
		linelen--;
		actionAndOptionsLen++;
	}

	//skip the ']' char
	line++;
	linelen--;

	//the first char after ']' is the field separator used for the whole line
	NSString *sparatorStr = nil;
	if(linelen > 0)
	{
		sparatorStr = CFBridgingRelease(CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)line, 1, kCFStringEncodingUTF8, false));
		line++;
		linelen--;
	}

	if((sparatorStr == nil) || (linelen == 0))
		return nil;

	NSString *actionAndOptionsStr = nil;
	if(actionAndOptionsLen > 0)
	{
		actionAndOptionsStr = CFBridgingRelease(CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)actionAndOptions, actionAndOptionsLen, kCFStringEncodingUTF8, false));
	}

	if(actionAndOptionsStr == nil)
		return nil;

	//action must be the first word, options are space separated and optional
	NSArray<NSString*> *actionAndOptionsArray = [actionAndOptionsStr componentsSeparatedByString:@" "];
	NSUInteger actionAndOptionsCount = [actionAndOptionsArray count];
	NSString *actionName = nil;
	if(actionAndOptionsCount > 0) //should always be
		actionName = actionAndOptionsArray[0];
	if(actionName == nil)
		return nil;

	NSMutableDictionary *actionDescription = [NSMutableDictionary new];
	actionDescription[@"action"] = actionName;

	NSArray<NSString *> *paramArray = nil;
	NSString *paramString = CFBridgingRelease(CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)line, linelen, kCFStringEncodingUTF8, false));
	if(paramString != nil)
	{
		paramArray = [paramString componentsSeparatedByString:sparatorStr];
	}
	
	if(paramArray == nil) // not valid but let the parser report the error
		return actionDescription;
	
	bool isSourceDestAction = false;
	Action action = ActionFromName(actionName, &isSourceDestAction);
	if(action == kActionInvalid)
		return actionDescription; // defer error handling to parsing code

	NSUInteger paramCount = [paramArray count];

	if(isSourceDestAction)
	{ // these require 2 arguments but if malformed defer the error handling to parsing code
		if(paramCount > 0)
		{
			actionDescription[@"from"] = paramArray[0];
		}
		if(paramCount > 1)
		{
			actionDescription[@"to"] = paramArray[1];
		}
	}
	else
	{
		if(action == kFileActionDelete)
		{ // variable element input - all params are paths to delete
			actionDescription[@"items"] = paramArray;
		}
		else if(action == kFileActionCreate)
		{
			if([actionAndOptionsArray containsObject:@"directory"])
			{
				if(paramCount > 0)
					actionDescription[@"directory"] = paramArray[0];
			}
			else //[actionAndOptionsArray containsObject:@"file"]
			{
				if(paramCount > 0)
					actionDescription[@"file"] = paramArray[0];
				if(paramCount > 1)
					actionDescription[@"content"] = paramArray[1];
			}
		}
		else if(action == kActionExecuteTool)
		{ //first param is the tool to execute. the following params are arguments
			if(paramCount > 0)
			{
				actionDescription[@"tool"] = paramArray[0];
			}
			
			if(paramCount > 1)
			{
				NSArray<NSString *> *args = [paramArray subarrayWithRange:NSMakeRange(1, paramCount-1)];
				actionDescription[@"arguments"] = args;
			}
		}
		else if(action == kActionEcho)
		{
			if(paramCount > 0)
				actionDescription[@"text"] = paramArray[0];
		}
	}

	AddOptionsToActionDescription(actionDescription, actionAndOptionsArray);

	return actionDescription;
}
