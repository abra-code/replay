#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#import "StringAndPath.h"
#import "ActionFromName.h"
#include "GlobOverlap.h"
#include "FileSystemHelpers.h"
#include <string>
#include <vector>


static inline dispatch_block_t
CreateSourceDestinationAction(Action replayAction, std::string fromPath, std::string toPath, ReplayContext *context, NSDictionary *actionSettings, NSInteger actionIndex)
{
	if(fromPath.empty() || toPath.empty())
		return nil;

	dispatch_block_t action = NULL;
	switch(replayAction)
	{
		case kFileActionClone:
		{
            action = ^{ @autoreleasepool {
				ActionContext localContext = { .settings = actionSettings, .index = actionIndex };
				__unused bool isOK = CloneItem(fromPath, toPath, context, &localContext);
            }};
		}
		break;

		case kFileActionMove:
		{
            action = ^{ @autoreleasepool {
				ActionContext localContext = { .settings = actionSettings, .index = actionIndex };
				__unused bool isOK = MoveItem(fromPath, toPath, context, &localContext);
            }};
		}
		break;

		case kFileActionHardlink:
		{
            action = ^{ @autoreleasepool {
				ActionContext localContext = { .settings = actionSettings, .index = actionIndex };
				__unused bool isOK = HardlinkItem(fromPath, toPath, context, &localContext);
            }};
		}
		break;

		case kFileActionSymlink:
		{
            action = ^{ @autoreleasepool {
				ActionContext localContext = { .settings = actionSettings, .index = actionIndex };
				__unused bool isOK = SymlinkItem(fromPath, toPath, context, &localContext);
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
			auto expanded = ExpandEnvVars([onePath UTF8String], context);
			if(expanded.has_value())
			{
				NSURL *oneURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:expanded->c_str()]];
				[expandedPaths addObject:oneURL.absoluteURL.path];
			}
		}
		return expandedPaths;
	}
	return nil;
}

static inline NSArray<NSString*> *
PathArrayFromString(const std::string &path)
{
	if(!path.empty())
		return @[[NSString stringWithUTF8String:path.c_str()]];
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
			auto expandedSource = ExpandEnvVars([sourcePath UTF8String], context);
			auto expandedDest = ExpandEnvVars([destinationPath UTF8String], context);
			if(!expandedSource.has_value() || !expandedDest.has_value())
			{
				actionHandler(nil, nil, nil, nil, nil);
			}
			else if(globoverlap::is_glob_pattern(*expandedSource))
			{
				// Glob source: expand at execution time, act on each match.
				// "to" is treated as destination directory (multiple sources to one dir).
				std::string globPattern = *expandedSource;
				std::string capturedDestDir = *expandedDest;
				NSInteger actionIndex = ++(context->actionCounter);
				Action capturedAction = replayAction;

				action = ^{ @autoreleasepool {
					auto matches = expand_glob(globPattern);
					if(matches.empty())
					{
						std::string errStr = std::string("error: glob pattern \"") + globPattern + "\" matched no files\n";
						context->lastError.set(errStr, 1);
						PrintToStdErr(context, std::move(errStr));
						return;
					}
					for(const auto& match : matches)
					{
						if(context->stopOnError && (context->lastError.hasError()))
							break;
						auto slash = match.rfind('/');
						std::string fileName = (slash != std::string::npos) ? match.substr(slash + 1) : match;
						std::string destPath = capturedDestDir + "/" + fileName;
						ActionContext localContext = { .settings = stepDescription, .index = actionIndex };
						switch(capturedAction) {
							case kFileActionClone:    CloneItem(match, destPath, context, &localContext); break;
							case kFileActionMove:     MoveItem(match, destPath, context, &localContext); break;
							case kFileActionHardlink: HardlinkItem(match, destPath, context, &localContext); break;
							default: break;
						}
					}
				}};

				if(context->concurrent)
				{
					// The glob pattern is the input for dependency analysis
					if(replayAction == kFileActionMove)
						exclusiveInputs = PathArrayFromString(globPattern);
					else
						inputs = PathArrayFromString(globPattern);
					outputs = PathArrayFromString(capturedDestDir);
				}
				actionHandler(action, inputs, nil, exclusiveInputs, outputs);
			}
			else
			{
				// Concrete source path — original behavior
				std::string fromPath = *expandedSource;
				std::string toPath = *expandedDest;

				NSInteger actionIndex = ++(context->actionCounter);
				action = CreateSourceDestinationAction(replayAction, fromPath, toPath, context, stepDescription, actionIndex);

				if(context->concurrent)
				{
					if(replayAction == kFileActionMove)
						exclusiveInputs = PathArrayFromString(fromPath);
					else
						inputs = PathArrayFromString(fromPath);
					outputs = PathArrayFromString(toPath);
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
				std::string capturedDestDir;
				auto expandedDestOpt = ExpandEnvVars([destinationDirPath UTF8String], context);
				if(expandedDestOpt.has_value())
					capturedDestDir = *expandedDestOpt;

				for(NSString *onePath in itemPaths)
				{
					auto expandedOpt = ExpandEnvVars([onePath UTF8String], context);
					if(!expandedOpt.has_value())
					{
						if(context->stopOnError)
							break;
						continue;
					}

					if(globoverlap::is_glob_pattern(*expandedOpt))
					{
						// Glob item: expand at execution time, act on each match
						std::string globPattern = *expandedOpt;
						NSInteger actionIndex = ++(context->actionCounter);
						Action capturedAction = replayAction;

						action = ^{ @autoreleasepool {
							auto matches = expand_glob(globPattern);
							if(matches.empty())
							{
								std::string errStr = std::string("error: glob pattern \"") + globPattern + "\" matched no files\n";
								context->lastError.set(errStr, 1);
								PrintToStdErr(context, std::move(errStr));
								return;
							}
							for(const auto& match : matches)
							{
								if(context->stopOnError && (context->lastError.hasError()))
									break;
								auto slash = match.rfind('/');
								std::string fileName = (slash != std::string::npos) ? match.substr(slash + 1) : match;
								std::string destPath = capturedDestDir + "/" + fileName;
								ActionContext localContext = { .settings = stepDescription, .index = actionIndex };
								switch(capturedAction) {
									case kFileActionClone:    CloneItem(match, destPath, context, &localContext); break;
									case kFileActionMove:     MoveItem(match, destPath, context, &localContext); break;
									case kFileActionHardlink: HardlinkItem(match, destPath, context, &localContext); break;
									default: break;
								}
							}
						}};

						if(context->concurrent)
						{
							if(replayAction == kFileActionMove)
								exclusiveInputs = PathArrayFromString(globPattern);
							else
								inputs = PathArrayFromString(globPattern);
							outputs = PathArrayFromString(capturedDestDir);
						}
						actionHandler(action, inputs, nil, exclusiveInputs, outputs);
					}
					else
					{
						// Concrete item — original behavior
						std::string srcPath = *expandedOpt;
						auto slash = srcPath.rfind('/');
						std::string fileName = (slash != std::string::npos) ? srcPath.substr(slash + 1) : srcPath;
						std::string dstPath = capturedDestDir + "/" + fileName;
						NSInteger actionIndex = ++(context->actionCounter);
						action = CreateSourceDestinationAction(replayAction, srcPath, dstPath, context, stepDescription, actionIndex);

						if(context->concurrent)
						{
							if(replayAction == kFileActionMove)
								exclusiveInputs = PathArrayFromString(srcPath);
							else
								inputs = PathArrayFromString(srcPath);
							outputs = PathArrayFromString(dstPath);
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
					auto expandedOpt = ExpandEnvVars([onePath UTF8String], context);
					if(expandedOpt.has_value())
					{
						if(globoverlap::is_glob_pattern(*expandedOpt))
						{
							// Glob item: expand at execution time, delete each match
							std::string globPattern = *expandedOpt;
							NSInteger actionIndex = ++(context->actionCounter);

							action = ^{ @autoreleasepool {
								auto matches = expand_glob(globPattern);
								if(matches.empty())
								{
									std::string errStr = std::string("error: glob pattern \"") + globPattern + "\" matched no files\n";
									context->lastError.set(errStr, 1);
									PrintToStdErr(context, std::move(errStr));
									return;
								}
								for(const auto& match : matches)
								{
									if(context->stopOnError && (context->lastError.hasError()))
										break;
									ActionContext localContext = { .settings = stepDescription, .index = actionIndex };
									__unused bool isOK = DeleteItem(match, context, &localContext);
								}
							}};

							if(context->concurrent)
							{
								exclusiveInputs = PathArrayFromString(globPattern);
							}
							actionHandler(action, nil, nil, exclusiveInputs, nil);
						}
						else
						{
							// Concrete item — original behavior
							std::string capturedPath = *expandedOpt;
							NSInteger actionIndex = ++(context->actionCounter);
							action = ^{ @autoreleasepool {
								ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
								__unused bool isOK = DeleteItem(capturedPath, context, &actionContext);
							}};

							if(context->concurrent)
							{
								exclusiveInputs = PathArrayFromString(capturedPath);
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
					auto expandedOpt = ExpandEnvVars([onePath UTF8String], context);
					if(expandedOpt.has_value())
					{
						std::string capturedPath = *expandedOpt;
						NSInteger actionIndex = ++(context->actionCounter);
						action = ^{ @autoreleasepool {
							ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
							__unused bool isOK = ReadFile(capturedPath, context, &actionContext);
						}};
						// ReadFile prints two strings (verbose descriptor + content), reserve second slot
						++(context->actionCounter);

						if(context->concurrent)
						{
							inputs = PathArrayFromString(capturedPath);
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
				auto expandedOpt = ExpandEnvVars([dirPath UTF8String], context);
				if(expandedOpt.has_value())
				{
					std::string capturedPath = *expandedOpt;
					NSInteger actionIndex = ++(context->actionCounter);
					action = ^{ @autoreleasepool {
						ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
						__unused bool isOK = ListDirectory(capturedPath, context, &actionContext);
					}};
					++(context->actionCounter);

					if(context->concurrent)
					{
						inputs = PathArrayFromString(capturedPath);
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
				auto expandedOpt = ExpandEnvVars([dirPath UTF8String], context);
				if(expandedOpt.has_value())
				{
					std::string capturedPath = *expandedOpt;
					NSInteger maxDepth = 5;
					id depthVal = stepDescription[@"depth"];
					if([depthVal isKindOfClass:[NSNumber class]])
						maxDepth = [depthVal integerValue];
					NSInteger capturedDepth = maxDepth;
					NSInteger actionIndex = ++(context->actionCounter);
					action = ^{ @autoreleasepool {
						ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
						__unused bool isOK = DirectoryTree(capturedPath, capturedDepth, context, &actionContext);
					}};
					++(context->actionCounter);

					if(context->concurrent)
					{
						inputs = PathArrayFromString(capturedPath);
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
				auto expandedOpt = ExpandEnvVars([filePath UTF8String], context);
				if(expandedOpt.has_value())
				{
					std::string capturedPath = *expandedOpt;
					NSInteger actionIndex = ++(context->actionCounter);
					action = ^{ @autoreleasepool {
						ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
						__unused bool isOK = GetFileInfo(capturedPath, context, &actionContext);
					}};
					++(context->actionCounter);

					if(context->concurrent)
					{
						inputs = PathArrayFromString(capturedPath);
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
					if(ep != nil)
						[expandedGlobs addObject:ep];
				}

				NSArray<NSString*> *rawExcludes = stepDescription[@"exclude"];
				NSMutableArray<NSString*> *expandedExcludes = [NSMutableArray new];
				if([rawExcludes isKindOfClass:arrayClass])
				{
					for(NSString *p in rawExcludes)
					{
						NSString *ep = StringByExpandingEnvironmentVariablesWithErrorCheck(p, context);
						if(ep != nil)
							[expandedExcludes addObject:ep];
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
			std::vector<FileEdit> editsVec;
			bool editsOK = false;
			NSArray<NSDictionary*> *rawEditsArray = stepDescription[@"edits"];
			if([rawEditsArray isKindOfClass:arrayClass] && [rawEditsArray count] > 0)
			{
				for(NSDictionary *editDict in rawEditsArray)
				{
					if(![editDict isKindOfClass:[NSDictionary class]])
					continue;
					NSString *oldText = editDict[@"oldText"];
					if(![oldText isKindOfClass:stringClass])
					continue;
					FileEdit fe;
					fe.old_text = [oldText UTF8String];
					id newTextVal = editDict[@"newText"];
					fe.new_text = [newTextVal isKindOfClass:stringClass] ? [newTextVal UTF8String] : "";
					id limitVal = editDict[@"limit"];
					if([limitVal isKindOfClass:[NSNumber class]])
						fe.limit = (int)[limitVal integerValue];
					id regexVal = editDict[@"regex"];
					if([regexVal isKindOfClass:[NSNumber class]])
						fe.use_regex = (bool)[regexVal boolValue];
					id caseVal = editDict[@"case-insensitive"];
					if([caseVal isKindOfClass:[NSNumber class]])
						fe.case_insensitive = (bool)[caseVal boolValue];
					editsVec.push_back(std::move(fe));
				}
				editsOK = !editsVec.empty();
			}
			else
			{
				// Simple streaming form: oldText/newText at top level
				NSString *oldText = stepDescription[@"oldText"];
				if([oldText isKindOfClass:stringClass])
				{
					FileEdit fe;
					fe.old_text = [oldText UTF8String];
					id newTextVal = stepDescription[@"newText"];
					fe.new_text = [newTextVal isKindOfClass:stringClass] ? [newTextVal UTF8String] : "";
					id limitVal = stepDescription[@"limit"];
					if([limitVal isKindOfClass:[NSNumber class]])
						fe.limit = (int)[limitVal integerValue];
					id regexVal = stepDescription[@"regex"];
					if([regexVal isKindOfClass:[NSNumber class]])
						fe.use_regex = (bool)[regexVal boolValue];
					id caseVal = stepDescription[@"case-insensitive"];
					if([caseVal isKindOfClass:[NSNumber class]])
						fe.case_insensitive = (bool)[caseVal boolValue];
					editsVec.push_back(std::move(fe));
					editsOK = true;
				}
				else
				{
					std::string errStr = "error: \"edit\" action: \"edits\" array or \"oldText\" string is required\n";
					context->lastError.set(errStr, 1);
					PrintToStdErr(context, std::move(errStr));
				}
			}

			if(editsOK)
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

					auto expandedOpt = ExpandEnvVars([onePath UTF8String], context);
					if(!expandedOpt.has_value())
					{
						if(context->stopOnError)
						break;
						continue;
					}

					if(globoverlap::is_glob_pattern(*expandedOpt))
					{
						// Glob item: one task expands at runtime and edits each match
						std::string globPattern = *expandedOpt;
						std::vector<FileEdit> capturedEdits = editsVec;
						bool capturedDryRun = actionDryRun;
						NSInteger actionIndex = ++(context->actionCounter);
						action = ^{ @autoreleasepool {
							auto matches = expand_glob(globPattern);
							if(matches.empty())
							{
								std::string errStr = std::string("error: glob pattern \"") + globPattern + "\" matched no files\n";
								context->lastError.set(errStr, 1);
								PrintToStdErr(context, std::move(errStr));
								return;
							}
							for(const auto& match : matches)
							{
								if(context->stopOnError && (context->lastError.hasError()))
									break;
								ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
								__unused bool isOK = EditFile(match, capturedEdits, capturedDryRun, context, &actionContext);
							}
						}};
						++(context->actionCounter);

						if(context->concurrent)
							mutatingInputs = PathArrayFromString(globPattern);
						actionHandler(action, nil, mutatingInputs, nil, nil);
						mutatingInputs = nil;
					}
					else
					{
						// Concrete path: one task per file (tasks are independent, can run in parallel)
						std::string capturedPath = *expandedOpt;
						std::vector<FileEdit> capturedEdits = editsVec;
						bool capturedDryRun = actionDryRun;
						NSInteger actionIndex = ++(context->actionCounter);
						action = ^{ @autoreleasepool {
							ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
							__unused bool isOK = EditFile(capturedPath, capturedEdits, capturedDryRun, context, &actionContext);
						}};
						++(context->actionCounter);

						if(context->concurrent)
						{
							mutatingInputs = PathArrayFromString(capturedPath);
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
					auto pathOpt = ExpandEnvVars([filePath UTF8String], context);
					if(pathOpt.has_value())
					{
						std::string capturedPath = *pathOpt;
						std::string capturedBlob([blobContent UTF8String]);
						NSInteger actionIndex = ++(context->actionCounter);
						action = ^{ @autoreleasepool {
							ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
							__unused bool isOK = CreateFileFromBlob(capturedPath, capturedBlob, context, &actionContext);
						}};
						if(context->concurrent)
						{
							outputs = PathArrayFromString(capturedPath);
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

				std::string capturedContent;
				bool contentOK = true;
				if(expandContent)
				{
					auto contentOpt = ExpandEnvVars([content UTF8String], context);
					if(!contentOpt.has_value())
						contentOK = false;
					else
						capturedContent = *contentOpt;
				}
				else
				{
					capturedContent = [content UTF8String];
				}

				auto pathOpt = ExpandEnvVars([filePath UTF8String], context);

				// contentOK is false only if string is malformed or missing environment variable
				if(contentOK && pathOpt.has_value())
				{
					std::string capturedPath = *pathOpt;
					NSInteger actionIndex = ++(context->actionCounter);
                    action = ^{ @autoreleasepool {
						ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
						__unused bool isOK = CreateFile(capturedPath, capturedContent, context, &actionContext);
                    }};

					if(context->concurrent)
					{
						outputs = PathArrayFromString(capturedPath);
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
					auto pathOpt = ExpandEnvVars([dirPath UTF8String], context);
					if(pathOpt.has_value())
					{
						std::string capturedPath = *pathOpt;
						NSInteger actionIndex = ++(context->actionCounter);
                        action = ^{ @autoreleasepool {
							ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
							__unused bool isOK = CreateDirectory(capturedPath, context, &actionContext);
                        }};

						if(context->concurrent)
						{
							outputs = PathArrayFromString(capturedPath);
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
					auto expandedToolOpt = ExpandEnvVars([toolPath UTF8String], context);
					if(expandedToolOpt.has_value())
					{
						bool argsOK = true;
						std::vector<std::string> capturedArgs;
						capturedArgs.reserve([arguments count]);
						for(NSString *oneArg in arguments)
						{
							auto expandedArgOpt = ExpandEnvVars([oneArg UTF8String], context);
							if(expandedArgOpt.has_value())
							{
								capturedArgs.push_back(*expandedArgOpt);
							}
							else if(context->stopOnError)
							{ // one invalid string expansion stops all actions
								argsOK = false;
								break;
							}
						}

						if(argsOK)
						{
							std::string capturedToolPath = *expandedToolOpt;
							NSInteger actionIndex = ++(context->actionCounter);
							action = ^{ @autoreleasepool {
                                    ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
                                    __unused bool isOK = ExcecuteTool(capturedToolPath, capturedArgs, context, &actionContext);
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

			std::string capturedText;
			bool textOK = true;
			if(expandText)
			{
				auto expandedOpt = ExpandEnvVars([text UTF8String], context);
				if(!expandedOpt.has_value())
					textOK = false;
				else
					capturedText = *expandedOpt;
			}
			else
			{
				capturedText = [text UTF8String];
			}

			// capturedText is empty (textOK=false) only if string is malformed or missing environment variable
			if(textOK)
			{
				NSInteger actionIndex = ++(context->actionCounter);
				action = ^{ @autoreleasepool {
					ActionContext actionContext = { .settings = stepDescription, .index = actionIndex };
					__unused bool isOK = Echo(capturedText, context, &actionContext);
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
