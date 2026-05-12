#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#import "StringAndPath.h"
#import "ActionFromName.h"
#include "GlobOverlap.h"
#include "FileSystemHelpers.h"
#include <string>


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
	if(context->stopOnError && (context->lastError.hasError()))
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
	NSArray<NSString*> *mutatingInputs = nil;
	NSArray<NSString*> *exclusiveInputs = nil;
	NSArray<NSString*> *outputs = nil;

	if(isSrcDestAction)
	{
		NSString *sourcePath = stepDescription[@"from"];
		NSString *destinationPath = stepDescription[@"to"];
		if([sourcePath isKindOfClass:stringClass] && [destinationPath isKindOfClass:stringClass])
		{//simple one-to-one form
			sourcePath = StringByExpandingEnvironmentVariablesWithErrorCheck(sourcePath, context);
			destinationPath = StringByExpandingEnvironmentVariablesWithErrorCheck(destinationPath, context);
			if(sourcePath == nil || destinationPath == nil)
			{
				actionHandler(nil, nil, nil, nil, nil);
			}
			else if(globoverlap::is_glob_pattern(std::string([sourcePath UTF8String])))
			{
				// Glob source: expand at execution time, act on each match.
				// "to" is treated as destination directory (multiple sources to one dir).
				NSString *globPattern = sourcePath;
				NSURL *destinationDirURL = [NSURL fileURLWithPath:destinationPath isDirectory:YES];
				NSInteger actionIndex = ++(context->actionCounter);
				Action capturedAction = replayAction;

				action = ^{ @autoreleasepool {
					std::string pattern([globPattern UTF8String]);
					auto matches = expand_glob(pattern);
					if(matches.empty())
					{
						std::string errStr = std::string("error: glob pattern \"") + [globPattern UTF8String] + "\" matched no files\n";
						context->lastError.set(errStr, 1);
						PrintToStdErr(context, std::move(errStr));
						return;
					}
					for(const auto& match : matches)
					{
						if(context->stopOnError && (context->lastError.hasError()))
							break;
						NSString *matchPath = [NSString stringWithUTF8String:match.c_str()];
						NSURL *srcURL = [NSURL fileURLWithPath:matchPath];
						NSString *fileName = [matchPath lastPathComponent];
						NSURL *destURL = [destinationDirURL URLByAppendingPathComponent:fileName];
						ActionContext localContext = { .settings = stepDescription, .index = actionIndex };
						switch(capturedAction) {
							case kFileActionClone:    CloneItem(srcURL, destURL, context, &localContext); break;
							case kFileActionMove:     MoveItem(srcURL, destURL, context, &localContext); break;
							case kFileActionHardlink: HardlinkItem(srcURL, destURL, context, &localContext); break;
							default: break;
						}
					}
				}};

				if(context->concurrent)
				{
					// The glob pattern is the input for dependency analysis
					if(replayAction == kFileActionMove)
						exclusiveInputs = @[globPattern];
					else
						inputs = @[globPattern];
					outputs = PathArrayFromFileURL(destinationDirURL);
				}
				actionHandler(action, inputs, nil, exclusiveInputs, outputs);
			}
			else
			{
				// Concrete source path — original behavior
				NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
				NSURL *destinationURL = [NSURL fileURLWithPath:destinationPath];

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
				actionHandler(action, inputs, nil, exclusiveInputs, outputs);
			}
		}
		else
		{//multiple items to destination directory form
			NSArray<NSString*> *itemPaths = stepDescription[@"items"];
			NSString *destinationDirPath = stepDescription[@"destination directory"];
			if([itemPaths isKindOfClass:arrayClass] && [destinationDirPath isKindOfClass:stringClass])
			{
				NSURL *destinationDirectoryURL = nil;
				NSString *expandedDestinationDirPath = StringByExpandingEnvironmentVariablesWithErrorCheck(destinationDirPath, context);
				if(expandedDestinationDirPath != nil)
					destinationDirectoryURL = [NSURL fileURLWithPath:expandedDestinationDirPath isDirectory:YES];

				for(NSString *onePath in itemPaths)
				{
					NSString *expandedPath = StringByExpandingEnvironmentVariablesWithErrorCheck(onePath, context);
					if(expandedPath == nil)
					{
						if(context->stopOnError)
							break;
						continue;
					}

					if(globoverlap::is_glob_pattern(std::string([expandedPath UTF8String])))
					{
						// Glob item: expand at execution time, act on each match
						NSString *globPattern = expandedPath;
						NSInteger actionIndex = ++(context->actionCounter);
						Action capturedAction = replayAction;

						action = ^{ @autoreleasepool {
							std::string pattern([globPattern UTF8String]);
							auto matches = expand_glob(pattern);
							if(matches.empty())
							{
								std::string errStr = std::string("error: glob pattern \"") + [globPattern UTF8String] + "\" matched no files\n";
								context->lastError.set(errStr, 1);
								PrintToStdErr(context, std::move(errStr));
								return;
							}
							for(const auto& match : matches)
							{
								if(context->stopOnError && (context->lastError.hasError()))
									break;
								NSString *matchPath = [NSString stringWithUTF8String:match.c_str()];
								NSURL *srcURL = [NSURL fileURLWithPath:matchPath];
								NSString *fileName = [matchPath lastPathComponent];
								NSURL *destURL = [destinationDirectoryURL URLByAppendingPathComponent:fileName];
								ActionContext localContext = { .settings = stepDescription, .index = actionIndex };
								switch(capturedAction) {
									case kFileActionClone:    CloneItem(srcURL, destURL, context, &localContext); break;
									case kFileActionMove:     MoveItem(srcURL, destURL, context, &localContext); break;
									case kFileActionHardlink: HardlinkItem(srcURL, destURL, context, &localContext); break;
									default: break;
								}
							}
						}};

						if(context->concurrent)
						{
							if(replayAction == kFileActionMove)
								exclusiveInputs = @[globPattern];
							else
								inputs = @[globPattern];
							outputs = PathArrayFromFileURL(destinationDirectoryURL);
						}
						actionHandler(action, inputs, nil, exclusiveInputs, outputs);
					}
					else
					{
						// Concrete item — original behavior
						NSURL *srcItemURL = [NSURL fileURLWithPath:expandedPath];
						NSString *fileName = [expandedPath lastPathComponent];
						NSURL *destinationURL = [destinationDirectoryURL URLByAppendingPathComponent:fileName];
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
						actionHandler(action, inputs, nil, exclusiveInputs, outputs);
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
						if(globoverlap::is_glob_pattern(std::string([expandedPath UTF8String])))
						{
							// Glob item: expand at execution time, delete each match
							NSString *globPattern = expandedPath;
							NSInteger actionIndex = ++(context->actionCounter);

							action = ^{ @autoreleasepool {
								std::string pattern([globPattern UTF8String]);
								auto matches = expand_glob(pattern);
								if(matches.empty())
								{
									std::string errStr = std::string("error: glob pattern \"") + [globPattern UTF8String] + "\" matched no files\n";
									context->lastError.set(errStr, 1);
									PrintToStdErr(context, std::move(errStr));
									return;
								}
								for(const auto& match : matches)
								{
									if(context->stopOnError && (context->lastError.hasError()))
										break;
									NSString *matchPath = [NSString stringWithUTF8String:match.c_str()];
									NSURL *matchURL = [NSURL fileURLWithPath:matchPath];
									ActionContext localContext = { .settings = stepDescription, .index = actionIndex };
									__unused bool isOK = DeleteItem(matchURL, context, &localContext);
								}
							}};

							if(context->concurrent)
							{
								exclusiveInputs = @[globPattern];
							}
							actionHandler(action, nil, nil, exclusiveInputs, nil);
						}
						else
						{
							// Concrete item — original behavior
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
							actionHandler(action, nil, nil, exclusiveInputs, nil);
						}
					}
					else if(context->stopOnError)
					{ // one invalid path stops all actions
						break;
					}
				}
			}
			else
			{
				std::string errStr = "error: \"delete\" action: \"items\" is expected to be an array of paths\n";
				context->lastError.set(errStr, 1);
				PrintToStdErr(context, std::move(errStr));
			}
		}
		else if(replayAction == kFileActionRead)
		{
			NSArray<NSString*> *itemPaths = stepDescription[@"items"];
			if([itemPaths isKindOfClass:arrayClass])
			{
				for(NSString *onePath in itemPaths)
				{
					NSString *expandedPath = StringByExpandingEnvironmentVariablesWithErrorCheck(onePath, context);
					if(expandedPath != nil)
					{
						NSString *capturedPath = expandedPath;
						NSInteger actionIndex = ++(context->actionCounter);
						action = ^{ @autoreleasepool {
							ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
							__unused bool isOK = ReadFile([capturedPath UTF8String], context, &actionContext);
						}};
						// ReadFile prints two strings (verbose descriptor + content), reserve second slot
						++(context->actionCounter);

						if(context->concurrent)
						{
							NSURL *itemURL = [NSURL fileURLWithPath:expandedPath];
							inputs = PathArrayFromFileURL(itemURL);
						}
						actionHandler(action, inputs, nil, nil, nil);
					}
					else if(context->stopOnError)
					{
						break;
					}
				}
			}
			else
			{
				std::string errStr = "error: \"read\" action: \"items\" is expected to be an array of paths\n";
				context->lastError.set(errStr, 1);
				PrintToStdErr(context, std::move(errStr));
			}
		}
		else if(replayAction == kFileActionList)
		{
			NSString *dirPath = stepDescription[@"directory"];
			if([dirPath isKindOfClass:stringClass])
			{
				NSString *expandedPath = StringByExpandingEnvironmentVariablesWithErrorCheck(dirPath, context);
				if(expandedPath != nil)
				{
					NSString *capturedPath = expandedPath;
					NSInteger actionIndex = ++(context->actionCounter);
					action = ^{ @autoreleasepool {
						ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
						__unused bool isOK = ListDirectory([capturedPath UTF8String], context, &actionContext);
					}};
					++(context->actionCounter);

					if(context->concurrent)
					{
						NSURL *dirURL = [NSURL fileURLWithPath:expandedPath];
						inputs = PathArrayFromFileURL(dirURL);
					}
					actionHandler(action, inputs, nil, nil, nil);
				}
			}
			else
			{
				std::string errStr = "error: \"list\" action: \"directory\" path is required\n";
				context->lastError.set(errStr, 1);
				PrintToStdErr(context, std::move(errStr));
			}
		}
		else if(replayAction == kFileActionTree)
		{
			NSString *dirPath = stepDescription[@"directory"];
			if([dirPath isKindOfClass:stringClass])
			{
				NSString *expandedPath = StringByExpandingEnvironmentVariablesWithErrorCheck(dirPath, context);
				if(expandedPath != nil)
				{
					NSString *capturedPath = expandedPath;
					NSInteger maxDepth = 5;
					id depthVal = stepDescription[@"depth"];
					if([depthVal isKindOfClass:[NSNumber class]])
						maxDepth = [depthVal integerValue];
					NSInteger capturedDepth = maxDepth;
					NSInteger actionIndex = ++(context->actionCounter);
					action = ^{ @autoreleasepool {
						ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
						__unused bool isOK = DirectoryTree([capturedPath UTF8String], capturedDepth, context, &actionContext);
					}};
					++(context->actionCounter);

					if(context->concurrent)
					{
						NSURL *dirURL = [NSURL fileURLWithPath:expandedPath];
						inputs = PathArrayFromFileURL(dirURL);
					}
					actionHandler(action, inputs, nil, nil, nil);
				}
			}
			else
			{
				std::string errStr = "error: \"tree\" action: \"directory\" path is required\n";
				context->lastError.set(errStr, 1);
				PrintToStdErr(context, std::move(errStr));
			}
		}
		else if(replayAction == kFileActionInfo)
		{
			NSString *filePath = stepDescription[@"path"];
			if([filePath isKindOfClass:stringClass])
			{
				NSString *expandedPath = StringByExpandingEnvironmentVariablesWithErrorCheck(filePath, context);
				if(expandedPath != nil)
				{
					NSString *capturedPath = expandedPath;
					NSInteger actionIndex = ++(context->actionCounter);
					action = ^{ @autoreleasepool {
						ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
						__unused bool isOK = GetFileInfo([capturedPath UTF8String], context, &actionContext);
					}};
					++(context->actionCounter);

					if(context->concurrent)
					{
						NSURL *itemURL = [NSURL fileURLWithPath:expandedPath];
						inputs = PathArrayFromFileURL(itemURL);
					}
					actionHandler(action, inputs, nil, nil, nil);
				}
			}
			else
			{
				std::string errStr = "error: \"info\" action: \"path\" is required\n";
				context->lastError.set(errStr, 1);
				PrintToStdErr(context, std::move(errStr));
			}
		}
		else if(replayAction == kFileActionGlob)
		{
			NSString *rawRoot = stepDescription[@"root"];
			NSArray<NSString*> *rawGlobs = stepDescription[@"glob"];

			if([rawRoot isKindOfClass:stringClass] && [rawGlobs isKindOfClass:arrayClass] && [rawGlobs count] > 0)
			{
				NSString *expandedRoot = StringByExpandingEnvironmentVariablesWithErrorCheck(rawRoot, context);
				if(expandedRoot == nil)
					expandedRoot = rawRoot;

				NSMutableArray<NSString*> *expandedGlobs = [NSMutableArray new];
				for(NSString *p in rawGlobs)
				{
					NSString *ep = StringByExpandingEnvironmentVariablesWithErrorCheck(p, context);
					if(ep != nil) [expandedGlobs addObject:ep];
				}

				NSArray<NSString*> *rawExcludes = stepDescription[@"exclude"];
				NSMutableArray<NSString*> *expandedExcludes = [NSMutableArray new];
				if([rawExcludes isKindOfClass:arrayClass])
				{
					for(NSString *p in rawExcludes)
					{
						NSString *ep = StringByExpandingEnvironmentVariablesWithErrorCheck(p, context);
						if(ep != nil) [expandedExcludes addObject:ep];
					}
				}

				NSInteger maxResults = 1000;
				id maxVal = stepDescription[@"max"];
				if([maxVal isKindOfClass:[NSNumber class]])
					maxResults = [maxVal integerValue];

				NSString *capturedRoot = expandedRoot;
				NSArray<NSString*> *capturedGlobs = [expandedGlobs copy];
				NSArray<NSString*> *capturedExcludes = [expandedExcludes copy];
				NSInteger capturedMax = maxResults;
				NSInteger actionIndex = ++(context->actionCounter);
				action = ^{ @autoreleasepool {
					ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
					__unused bool isOK = GlobFiles(capturedRoot, capturedGlobs, capturedExcludes, capturedMax, context, &actionContext);
				}};
				++(context->actionCounter);

				if(context->concurrent)
				{
					inputs = @[expandedRoot];
				}
				actionHandler(action, inputs, nil, nil, nil);
			}
			else
			{
				std::string errStr = "error: \"glob\" action: \"root\" string and \"glob\" array are required\n";
				context->lastError.set(errStr, 1);
				PrintToStdErr(context, std::move(errStr));
			}
		}
		else if(replayAction == kFileActionEdit)
		{
			// Resolve edits specification (shared across all items)
			NSArray<NSDictionary*> *editsArray = stepDescription[@"edits"];
			if(![editsArray isKindOfClass:arrayClass] || [editsArray count] == 0)
			{
				// Simple streaming form: oldText/newText at top level
				NSString *oldText = stepDescription[@"oldText"];
				if([oldText isKindOfClass:stringClass])
				{
					NSMutableDictionary *singleEdit = [NSMutableDictionary dictionary];
					singleEdit[@"oldText"] = oldText;
					id newTextVal = stepDescription[@"newText"];
					singleEdit[@"newText"] = [newTextVal isKindOfClass:stringClass] ? newTextVal : @"";
					for(NSString *key in @[@"limit", @"regex", @"case-insensitive"])
					{
						id val = stepDescription[key];
						if(val != nil) singleEdit[key] = val;
					}
					editsArray = @[singleEdit];
				}
				else
				{
					std::string errStr = "error: \"edit\" action: \"edits\" array or \"oldText\" string is required\n";
					context->lastError.set(errStr, 1);
					PrintToStdErr(context, std::move(errStr));
					editsArray = nil;
				}
			}

			if(editsArray != nil)
			{
				bool actionDryRun = false;
				id dryRunVal = stepDescription[@"dry-run"];
				if([dryRunVal isKindOfClass:[NSNumber class]])
					actionDryRun = [dryRunVal boolValue];

				NSArray<NSString*> *itemPaths = stepDescription[@"items"];
				if(![itemPaths isKindOfClass:arrayClass] || [itemPaths count] == 0)
				{
					std::string errStr = "error: \"edit\" action: \"items\" array of paths is required\n";
					context->lastError.set(errStr, 1);
					PrintToStdErr(context, std::move(errStr));
					itemPaths = nil;
				}

				for(NSString *onePath in itemPaths)
				{
					if(context->stopOnError && (context->lastError.hasError()))
						break;

					NSString *expandedPath = StringByExpandingEnvironmentVariablesWithErrorCheck(onePath, context);
					if(expandedPath == nil)
					{
						if(context->stopOnError) break;
						continue;
					}

					if(globoverlap::is_glob_pattern(std::string([expandedPath UTF8String])))
					{
						// Glob item: one task expands at runtime and edits each match
						NSString *globPattern = expandedPath;
						NSArray<NSDictionary*> *capturedEdits = editsArray;
						bool capturedDryRun = actionDryRun;
						NSInteger actionIndex = ++(context->actionCounter);
						action = ^{ @autoreleasepool {
							std::string pattern([globPattern UTF8String]);
							auto matches = expand_glob(pattern);
							if(matches.empty())
							{
								std::string errStr = std::string("error: glob pattern \"") + [globPattern UTF8String] + "\" matched no files\n";
								context->lastError.set(errStr, 1);
								PrintToStdErr(context, std::move(errStr));
								return;
							}
							for(const auto& match : matches)
							{
								if(context->stopOnError && (context->lastError.hasError()))
									break;
								ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
								__unused bool isOK = EditFile(match.c_str(), capturedEdits, capturedDryRun, context, &actionContext);
							}
						}};
						++(context->actionCounter);

						if(context->concurrent)
							mutatingInputs = @[globPattern];
						actionHandler(action, nil, mutatingInputs, nil, nil);
						mutatingInputs = nil;
					}
					else
					{
						// Concrete path: one task per file (tasks are independent, can run in parallel)
						NSString *capturedPath = expandedPath;
						NSArray<NSDictionary*> *capturedEdits = editsArray;
						bool capturedDryRun = actionDryRun;
						NSInteger actionIndex = ++(context->actionCounter);
						action = ^{ @autoreleasepool {
							ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
							__unused bool isOK = EditFile([capturedPath UTF8String], capturedEdits, capturedDryRun, context, &actionContext);
						}};
						++(context->actionCounter);

						if(context->concurrent)
						{
							NSURL *fileURL = [NSURL fileURLWithPath:expandedPath];
							mutatingInputs = PathArrayFromFileURL(fileURL);
						}
						actionHandler(action, nil, mutatingInputs, nil, nil);
						mutatingInputs = nil;
					}
				}
			}
		}
		else if(replayAction == kFileActionCreate)
		{
			NSString *filePath = stepDescription[@"file"];
			if([filePath isKindOfClass:stringClass])
			{
				// blob (base64 binary) takes priority over text content
				NSString *blobContent = nil;
				id blobValue = stepDescription[@"blob"];
				if([blobValue isKindOfClass:stringClass])
				{
					// JSON/plist format: "blob": "<base64>" key holds the data
					blobContent = blobValue;
				}
				else if([blobValue isKindOfClass:[NSNumber class]] && [blobValue boolValue])
				{
					// streaming format: blob=true modifier, "content" holds the base64 data
					id contentValue = stepDescription[@"content"];
					if([contentValue isKindOfClass:stringClass])
						blobContent = contentValue;
				}

				if(blobContent != nil)
				{
					NSString *expandedPath = StringByExpandingEnvironmentVariablesWithErrorCheck(filePath, context);
					if(expandedPath != nil)
					{
						NSURL *fileURL = [NSURL fileURLWithPath:expandedPath];
						NSString *capturedBlob = blobContent;
						NSInteger actionIndex = ++(context->actionCounter);
						action = ^{ @autoreleasepool {
							ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
							__unused bool isOK = CreateFileFromBlob(fileURL, capturedBlob, context, &actionContext);
						}};
						if(context->concurrent)
						{
							outputs = PathArrayFromFileURL(fileURL);
						}
						actionHandler(action, nil, nil, nil, outputs);
					}
				}
				else
				{
				NSString *content = stepDescription[@"content"];
				if(content == nil)
					content = @""; //content is optional
				if(![content isKindOfClass:stringClass])
				{
					PrintToStdErr(context, "error: \"create file\" action: \"content\" is expected to be a string\n");
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
					actionHandler(action, nil, nil, nil, outputs);
				}
				} // end else (not blob)
			} // end if(filePath)
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
						actionHandler(action, nil, nil, nil, outputs);
					}
				}
				else
				{
					std::string errStr = "error: \"create\" action must specify \"file\" or \"directory\"\n";
					context->lastError.set(errStr, 1);
					PrintToStdErr(context, std::move(errStr));
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
					std::string errStr = "error: \"execute\" action must specify \"arguments\" as a string array\n";
					context->lastError.set(errStr, 1);
					PrintToStdErr(context, std::move(errStr));
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

							actionHandler(action, inputs, nil, exclusiveInputs, outputs);
						}
					}
				}
			}
			else
			{
				std::string errStr = "error: \"execute\" action must specify \"tool\" value with path to executable\n";
				context->lastError.set(errStr, 1);
				PrintToStdErr(context, std::move(errStr));
			}
		}
		else if(replayAction == kActionEcho)
		{
			NSString *text = stepDescription[@"text"];

			if(text == nil)
				text = @"";

			if(![text isKindOfClass:stringClass])
			{
				PrintToStdErr(context, "error: \"echo\" action: \"text\" is expected to be a string\n");
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

				actionHandler(action, nil, nil, nil, outputs);
			}
		}
		else if((replayAction == kActionWait) || (replayAction == kActionStartServer))
		{
			// we should never arrive here with this pseudo-action
			assert((replayAction != kActionWait) && (replayAction != kActionStartServer));
		}
	}
 } //autoreleasepool
}
