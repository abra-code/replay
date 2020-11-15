#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "StringAndPath.h"

//a helper class to ensure atomic access to shared NSError from multiple threads
@implementation AtomicError

@end


static inline Action
StepAction(NSDictionary *stepDescription, bool *isSrcDestActionPtr)
{
	NSString *actionName = stepDescription[@"action"];
	if(actionName == nil)
	{
		fprintf(stderr, "error: action not specified in a step.\n");
		return kActionInvalid;
	}

	Action fileAction = kActionInvalid;
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
	else if([actionName isEqualToString:@"execute"])
	{
		fileAction = kActionExecuteTool;
		isSrcDestAction = false;
	}
	else
	{
		fileAction = kActionInvalid;
		fprintf(stderr, "error: unrecognized step action: %s\n", [actionName UTF8String]);
	}

	*isSrcDestActionPtr = isSrcDestAction;
	return fileAction;
}


static inline dispatch_block_t
CreateSourceDestinationAction(Action fileAction, NSURL *sourceURL, NSURL *destinationURL, ReplayContext *context, NSDictionary *actionSettings)
{
	if((sourceURL == nil) || (destinationURL == nil))
		return nil;

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

void
HandleActionStep(NSDictionary *stepDescription, ReplayContext *context, action_handler_t actionHandler)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return;

	bool isSrcDestAction = false;
	Action fileAction = StepAction(stepDescription, &isSrcDestAction);

	if(fileAction == kActionInvalid)
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
			action = CreateSourceDestinationAction(fileAction, sourceURL, destinationURL, context, stepDescription);
			
			if(context->concurrent)
			{
				if(fileAction == kFileActionMove)
					exclusiveInputs = @[sourceURL.absoluteURL.path];
				else
					inputs = @[sourceURL.absoluteURL.path];
				outputs = @[destinationURL.absoluteURL.path];
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
						action = CreateSourceDestinationAction(fileAction, srcItemURL, destinationURL, context, stepDescription);
						
						if(context->concurrent)
						{
							if(fileAction == kFileActionMove)
								exclusiveInputs = @[srcItemURL.absoluteURL.path];
							else
								inputs = @[srcItemURL.absoluteURL.path];
							outputs = @[destinationURL.absoluteURL.path];
						}
						actionHandler(action, inputs, exclusiveInputs, outputs);
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
						
						if(context->concurrent)
						{
							exclusiveInputs = @[oneURL.absoluteURL.path];
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
					fprintf(stderr, "error: \"content\" is expected to be a string\n");
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
					
					if(context->concurrent)
					{
						outputs = @[fileURL.absoluteURL.path];
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
						action = ^{
							__unused bool isOK = CreateDirectory(dirURL, context, stepDescription);
						};
						
						if(context->concurrent)
						{
							outputs = @[dirURL.absoluteURL.path];
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
		else if(fileAction == kActionExecuteTool)
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
							action = ^{
								__unused bool isOK = ExcecuteTool(expandedToolPath, expandedArgs, context, stepDescription);
							};
							
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
	}
}


bool
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
			fprintf(stderr, "error: failed to clone from \"%s\" to \"%s\". Error: %s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

bool
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
			fprintf(stderr, "error: failed to move from \"%s\" to \"%s\". Error: %s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

bool
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
			fprintf(stderr, "error: failed to create a hardlink from \"%s\" to \"%s\". Error: %s\n", [[fromURL path] UTF8String], [[toURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

bool
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
			fprintf(stderr, "error: failed to create a symlink at \"%s\" referring to \"%s\". Error: %s\n", [[linkURL path] UTF8String], [[fromURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

bool
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
			fprintf(stderr, "error: failed to create file \"%s\". Error: %s\n", [[itemURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

bool
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
			fprintf(stderr, "error: failed to create directory \"%s\". Error: %s\n", [[itemURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

bool
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
			fprintf(stderr, "error: failed to delete \"%s\". Error: %s\n", [[itemURL path] UTF8String], [errorDesc UTF8String] );
		}
	}
	return isSuccessful;
}

bool
ExcecuteTool(NSString *toolPath, NSArray<NSString*> *arguments, ReplayContext *context, NSDictionary *actionSettings)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *allArgsStr = [arguments componentsJoinedByString:@"\t"];
		fprintf(stdout, "[execute]	%s	%s\n", [toolPath UTF8String], [allArgsStr UTF8String]);
	}

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

		NSFileHandle *stdOutFileHandle = [stdOutPipe fileHandleForReading];

		NSError *operationError = nil;
		isSuccessful = (bool)[task launchAndReturnError:&operationError];
		if(isSuccessful)
		{
			NSData *stdOutData = [stdOutFileHandle readDataToEndOfFileAndReturnError:&operationError];
			if(stdOutData != nil)
			{
				if(context->verbose)
				{
					//since we captured stdout and waited on it, now replay it to stdout
					//because it was synchronous, all output will be printed at once after the tool finished
					NSString *stdOutString = [[NSString alloc] initWithData:stdOutData encoding:NSUTF8StringEncoding];
					fprintf(stdout, "%s\n", [stdOutString UTF8String]);
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
	return isSuccessful;
}
