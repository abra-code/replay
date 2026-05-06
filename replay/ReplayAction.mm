#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "StringAndPath.h"
#import "OutputSerializer.h"
#import "ActionFromName.h"
#include "GlobOverlap.h"
#include "ABase64.h"
#include "FileSystemHelpers.h"
#include <fts.h>
#include <sys/stat.h>
#include <cerrno>
#include <fstream>
#include <vector>
#include <string>

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

static inline void PrintToStdErr(ReplayContext *context, NSString *string)
{
	PrintSerializedErrorString(context->outputSerializer, string);
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

// ============================================================================
// Filesystem glob expansion
//
// Expands an absolute glob pattern (e.g. /Users/foo/build/**/*.o) into a list
// of matching file paths by walking the filesystem with fts_read.
// The pattern is split into a concrete directory prefix (longest path with no
// metacharacters) and a glob suffix matched against relative paths from there.
// ============================================================================

static std::string concrete_prefix_of_glob(const std::string& pattern) {
	// Find the last '/' before the first metacharacter
	size_t meta_pos = std::string::npos;
	for (size_t i = 0; i < pattern.size(); i++) {
		char c = pattern[i];
		if (c == '*' || c == '?' || c == '[' || c == '{') {
			meta_pos = i;
			break;
		}
	}
	if (meta_pos == std::string::npos)
		return pattern; // no metacharacters — entire path is concrete

	size_t last_slash = pattern.rfind('/', meta_pos);
	if (last_slash == std::string::npos)
		return ".";
	return pattern.substr(0, last_slash);
}

static std::vector<std::string> expand_glob_on_filesystem(const std::string& pattern) {
	std::vector<std::string> results;

	std::string base_dir = concrete_prefix_of_glob(pattern);
	// The glob suffix is the pattern relative to base_dir
	std::string glob_suffix = pattern.substr(base_dir.size());
	if (!glob_suffix.empty() && glob_suffix[0] == '/')
		glob_suffix = glob_suffix.substr(1);

	if (glob_suffix.empty()) {
		// No glob — pattern is a concrete path, just return it if it exists
		struct stat st;
		if (stat(pattern.c_str(), &st) == 0)
			results.push_back(pattern);
		return results;
	}

	// Compile the glob suffix for matching relative paths
	// Lowercase both pattern and paths for case-insensitive matching (macOS APFS default)
	std::string lowercase_suffix = glob_suffix;
	std::transform(lowercase_suffix.begin(), lowercase_suffix.end(),
				   lowercase_suffix.begin(), ::tolower);
	glob::glob compiled_glob(lowercase_suffix);

	char *paths[2] = { const_cast<char*>(base_dir.c_str()), nullptr };
	FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, nullptr);
	if (fts == nullptr)
		return results;

	FTSENT *ent;
	while ((ent = fts_read(fts)) != nullptr) {
		switch (ent->fts_info) {
			case FTS_F:
			case FTS_SL:
			case FTS_SLNONE: {
				const char *rel = ent->fts_path + base_dir.size();
				if (*rel == '/') ++rel;

				std::string lowercase_rel(rel);
				std::transform(lowercase_rel.begin(), lowercase_rel.end(),
							   lowercase_rel.begin(), ::tolower);

				if (glob_match(lowercase_rel, compiled_glob))
					results.emplace_back(ent->fts_path);
				break;
			}
			case FTS_ERR:
			case FTS_DNR:
				break;
			default:
				break;
		}
	}

	fts_close(fts);
	return results;
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
			sourcePath = StringByExpandingEnvironmentVariablesWithErrorCheck(sourcePath, context);
			destinationPath = StringByExpandingEnvironmentVariablesWithErrorCheck(destinationPath, context);
			if(sourcePath == nil || destinationPath == nil)
			{
				actionHandler(nil, nil, nil, nil);
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
					auto matches = expand_glob_on_filesystem(pattern);
					if(matches.empty())
					{
						NSString *errStr = [NSString stringWithFormat:
							@"error: glob pattern \"%@\" matched no files\n", globPattern];
						PrintToStdErr(context, errStr);
						NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: errStr };
						context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
						return;
					}
					for(const auto& match : matches)
					{
						if(context->stopOnError && (context->lastError.error != nil))
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
				actionHandler(action, inputs, exclusiveInputs, outputs);
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
				actionHandler(action, inputs, exclusiveInputs, outputs);
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
							auto matches = expand_glob_on_filesystem(pattern);
							if(matches.empty())
							{
								NSString *errStr = [NSString stringWithFormat:
									@"error: glob pattern \"%@\" matched no files\n", globPattern];
								PrintToStdErr(context, errStr);
								NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: errStr };
								context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
								return;
							}
							for(const auto& match : matches)
							{
								if(context->stopOnError && (context->lastError.error != nil))
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
						actionHandler(action, inputs, exclusiveInputs, outputs);
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
						if(globoverlap::is_glob_pattern(std::string([expandedPath UTF8String])))
						{
							// Glob item: expand at execution time, delete each match
							NSString *globPattern = expandedPath;
							NSInteger actionIndex = ++(context->actionCounter);

							action = ^{ @autoreleasepool {
								std::string pattern([globPattern UTF8String]);
								auto matches = expand_glob_on_filesystem(pattern);
								if(matches.empty())
								{
									NSString *errStr = [NSString stringWithFormat:
										@"error: glob pattern \"%@\" matched no files\n", globPattern];
									PrintToStdErr(context, errStr);
									NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: errStr };
									context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
									return;
								}
								for(const auto& match : matches)
								{
									if(context->stopOnError && (context->lastError.error != nil))
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
							actionHandler(action, nil, exclusiveInputs, nil);
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
							actionHandler(action, nil, exclusiveInputs, nil);
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
				NSString *errStr = @"error: \"delete\" action: \"items\" is expected to be an array of paths\n";
				PrintToStdErr(context, errStr);
				NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Unexpected items type" };
				NSError *operationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
				context->lastError.error = operationError;
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
						actionHandler(action, inputs, nil, nil);
					}
					else if(context->stopOnError)
					{
						break;
					}
				}
			}
			else
			{
				NSString *errStr = @"error: \"read\" action: \"items\" is expected to be an array of paths\n";
				PrintToStdErr(context, errStr);
				NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Unexpected items type" };
				NSError *operationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
				context->lastError.error = operationError;
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
					actionHandler(action, inputs, nil, nil);
				}
			}
			else
			{
				NSString *errStr = @"error: \"list\" action: \"directory\" path is required\n";
				PrintToStdErr(context, errStr);
				NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Missing directory path" };
				context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
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
					actionHandler(action, inputs, nil, nil);
				}
			}
			else
			{
				NSString *errStr = @"error: \"tree\" action: \"directory\" path is required\n";
				PrintToStdErr(context, errStr);
				NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Missing directory path" };
				context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
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
						actionHandler(action, nil, nil, outputs);
					}
				}
				else
				{
				NSString *content = stepDescription[@"content"];
				if(content == nil)
					content = @""; //content is optional
				if(![content isKindOfClass:stringClass])
				{
					NSString *errStr = @"error: \"create file\" action: \"content\" is expected to be a string\n";
					PrintToStdErr(context, errStr);
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
						actionHandler(action, nil, nil, outputs);
					}
				}
				else
				{
					NSString *errStr = @"error: \"create\" action must specify \"file\" or \"directory\" \n";
					PrintToStdErr(context, errStr);
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
					NSString *errStr = @"error: \"execute\" action must specify \"arguments\" as a string array\n";
					PrintToStdErr(context, errStr);
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
				NSString *errStr = @"error: \"execute\" action must specify \"tool\" value with path to executable\n";
				PrintToStdErr(context, errStr);
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
				NSString *errStr = @"error: \"echo\" action: \"text\" is expected to be a string\n";
				PrintToStdErr(context, errStr);
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
		else if((replayAction == kActionWait) || (replayAction == kActionStartServer))
		{
			// we should never arrive here with this pseudo-action
			assert((replayAction != kActionWait) && (replayAction != kActionStartServer));
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
			NSString *errStr = [NSString stringWithFormat:@"error: failed to clone from \"%@\" to \"%@\". Error: %@\n",
														[fromURL path],
														[toURL path],
														errorDesc];
			PrintToStdErr(context, errStr);
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
			NSString *errStr = [NSString stringWithFormat:@"error: failed to move from \"%@\" to \"%@\". Error: %@\n",
														[fromURL path],
														[toURL path],
														errorDesc];
			PrintToStdErr(context, errStr);
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
			NSString *errStr = [NSString stringWithFormat:@"error: failed to create a hardlink from \"%@\" to \"%@\". Error: %@\n",
														[fromURL path],
														[toURL path],
														errorDesc];
			PrintToStdErr(context, errStr);
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
			NSString *errStr = [NSString stringWithFormat:@"error: failed to create a symlink at \"%@\" referring to \"%@\". Error: %@\n",
														[linkURL path],
														[fromURL path],
														errorDesc];
			PrintToStdErr(context, errStr);
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
			NSString *errStr = [NSString stringWithFormat:@"error: failed to create file \"%@\". Error: %@\n",
														[itemURL path],
														errorDesc];
			PrintToStdErr(context, errStr);
		}
	}
	return isSuccessful;
}

bool
CreateFileFromBlob(NSURL *itemURL, NSString *base64Content, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[create file blob=true]\t%@\n", [itemURL path]];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	bool isSuccessful = context->dryRun;
	if(!context->dryRun)
	{
		const char *encoded = [base64Content UTF8String];
		unsigned long encodedLen = encoded ? strlen(encoded) : 0;
		unsigned long maxDecoded = CalculateDecodedBufferMaxSize(encodedLen);
		std::vector<unsigned char> decoded(maxDecoded > 0 ? maxDecoded : 1);
		unsigned long decodedLen = encodedLen > 0
			? DecodeBase64((const unsigned char *)encoded, encodedLen, decoded.data(), maxDecoded)
			: 0;

		const char *path = [[itemURL path] UTF8String];
		auto tryWrite = [&](const char *p) -> bool {
			std::ofstream f(p, std::ios::binary);
			if(!f.is_open()) return false;
			if(decodedLen > 0) f.write((const char *)decoded.data(), decodedLen);
			return f.good();
		};

		isSuccessful = tryWrite(path);
		if(!isSuccessful && context->force)
		{
			NSFileManager *fm = [NSFileManager defaultManager];
			[fm removeItemAtURL:itemURL error:nil];
			NSURL *parentDirURL = [itemURL URLByDeletingLastPathComponent];
			[fm createDirectoryAtURL:parentDirURL withIntermediateDirectories:YES attributes:nil error:nil];
			isSuccessful = tryWrite(path);
		}

		if(!isSuccessful)
		{
			int err = errno;
			NSString *errStr = [NSString stringWithFormat:@"error: failed to create file \"%@\". Error: %s\n",
								[itemURL path], strerror(err)];
			PrintToStdErr(context, errStr);
			NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: errStr };
			context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:userInfo];
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
			NSString *errStr = [NSString stringWithFormat:@"error: failed to create directory \"%@\". Error: %@\n",
														[itemURL path],
														errorDesc];
			PrintToStdErr(context, errStr);
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
			NSString *errStr = [NSString stringWithFormat:@"error: failed to delete \"%@\". Error: %@\n",
														[itemURL path],
														errorDesc];
			PrintToStdErr(context, errStr);
		}
	}
	return isSuccessful;
}

static bool is_utf8_text(const uint8_t *data, size_t len) {
	size_t i = 0;
	while (i < len) {
		uint8_t c = data[i];
		if (c == 0) return false;
		size_t seqLen;
		if      ((c & 0x80) == 0x00) seqLen = 1;
		else if ((c & 0xE0) == 0xC0) seqLen = 2;
		else if ((c & 0xF0) == 0xE0) seqLen = 3;
		else if ((c & 0xF8) == 0xF0) seqLen = 4;
		else return false;
		for (size_t j = 1; j < seqLen; j++) {
			if (i + j >= len || (data[i + j] & 0xC0) != 0x80) return false;
		}
		i += seqLen;
	}
	return true;
}

bool
ReadFile(const char *filePath, ReplayContext *context, ActionContext *actionContext)
{
	if (context->stopOnError && context->lastError.error != nil)
		return false;

	if (context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[read]\t%s\n", filePath];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	actionContext->index++;

	if (context->dryRun)
	{
		ActionWithNoOutput(context, actionContext->index);
		return true;
	}

	std::ifstream f(filePath, std::ios::binary | std::ios::ate);
	if (!f.is_open())
	{
		int err = errno;
		NSString *errStr = [NSString stringWithFormat:@"error: failed to open \"%s\" for reading: %s\n", filePath, strerror(err)];
		PrintToStdErr(context, errStr);
		NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: errStr };
		context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:userInfo];
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	std::streamoff fileSize = f.tellg();
	f.seekg(0, std::ios::beg);

	std::vector<uint8_t> data(static_cast<size_t>(fileSize));
	if (fileSize > 0 && !f.read(reinterpret_cast<char *>(data.data()), fileSize))
	{
		NSString *errStr = [NSString stringWithFormat:@"error: failed to read \"%s\"\n", filePath];
		PrintToStdErr(context, errStr);
		NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: errStr };
		context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:userInfo];
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	if (is_utf8_text(data.data(), data.size()))
	{
		NSString *header = [NSString stringWithFormat:@"[text:%s]\n", filePath];
		NSString *content = data.empty() ? @"" : [[NSString alloc] initWithBytes:data.data() length:data.size() encoding:NSUTF8StringEncoding];
		if (content == nil) content = @"";
		if (![content hasSuffix:@"\n"]) content = [content stringByAppendingString:@"\n"];
		PrintToStdOut(context, [header stringByAppendingString:content], actionContext->index);
	}
	else
	{
		unsigned long encodedSize = CalculateEncodedBufferSize((unsigned long)data.size());
		std::vector<unsigned char> encoded(encodedSize + 1, 0);
		unsigned long written = EncodeBase64(data.data(), (unsigned long)data.size(), encoded.data(), encodedSize);
		encoded[written] = '\0';

		NSString *header = [NSString stringWithFormat:@"[blob:%s]\n", filePath];
		NSString *encodedStr = [NSString stringWithUTF8String:(const char *)encoded.data()];
		if (encodedStr == nil) encodedStr = @"";
		PrintToStdOut(context, [[header stringByAppendingString:encodedStr] stringByAppendingString:@"\n"], actionContext->index);
	}

	return true;
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

		NSPipe *stdErrPipe = [NSPipe pipe];
		[task setStandardError:stdErrPipe];

		[task setTerminationHandler: ^(NSTask *task) {
			int toolStatus = [task terminationStatus];
			if(toolStatus != EXIT_SUCCESS)
			{
				NSError *dataError = nil;
				NSFileHandle *stdOutFileHandle = [stdErrPipe fileHandleForReading];
				NSData *stdErrData = [stdOutFileHandle readDataToEndOfFileAndReturnError:&dataError];
				if((stdErrData != nil) && (stdErrData.length > 0))
				{
					NSString *stdErrStr = [[NSString alloc] initWithData:stdErrData encoding:NSUTF8StringEncoding];
					PrintToStdErr(context, stdErrStr);
				}
				
				NSString *toolErrorDescription = [NSString stringWithFormat:@"%@ returned error %d", toolPath, toolStatus];
				NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: toolErrorDescription };
				NSError *taskError = [NSError errorWithDomain:NSPOSIXErrorDomain code:toolStatus userInfo:userInfo];
				context->lastError.error = taskError;
				NSString *errStr = [NSString stringWithFormat:@"error: failed to execute \"%@\". Error: %d\n", toolPath, toolStatus];
				PrintToStdErr(context, errStr);
			}
		}];

		NSPipe *stdOutPipe = [NSPipe pipe];
		[task setStandardOutput:stdOutPipe];

		NSPipe *stdInPipe = [NSPipe pipe];
		[task setStandardInput:stdInPipe];

		NSError *operationError = nil;
		isSuccessful = (bool)[task launchAndReturnError:&operationError];
		if(isSuccessful)
		{
			NSFileHandle *stdOutFileHandle = [stdOutPipe fileHandleForReading];
			NSData *stdOutData = [stdOutFileHandle readDataToEndOfFileAndReturnError:&operationError];
			if(stdOutData != nil)
			{
				if(useStdOut)
				{
					//since we captured stdout and waited on it, now replay it to stdout
					//because it was synchronous, all output will be printed at once after the tool finished
					NSString *stdOutStr = [[NSString alloc] initWithData:stdOutData encoding:NSUTF8StringEncoding];
					PrintToStdOut(context, stdOutStr, actionContext->index);
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
			NSString *errStr = [NSString stringWithFormat:@"error: failed to execute \"%@\". Error: %@\n", toolPath, errorDesc];
			PrintToStdErr(context, errStr);
		}
	}
	
	if(!secondStringPrinted)
	{
		ActionWithNoOutput(context, actionContext->index);
	}
	
	return isSuccessful;
}



bool
ListDirectory(const char *dirPath, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[list]\t%s\n", dirPath];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	actionContext->index++;

	if(context->dryRun)
	{
		ActionWithNoOutput(context, actionContext->index);
		return true;
	}

	std::vector<DirEntry> entries;
	if(!list_directory(dirPath, entries))
	{
		int err = errno;
		NSString *errStr = [NSString stringWithFormat:@"error: failed to list \"%s\": %s\n", dirPath, strerror(err)];
		PrintToStdErr(context, errStr);
		NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: errStr };
		context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:userInfo];
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	NSMutableString *output = [NSMutableString stringWithFormat:@"[list:%s]\n", dirPath];
	for(const auto &entry : entries)
	{
		[output appendFormat:@"[%s] %s\n", entry.isDirectory ? "DIR" : "FILE", entry.name.c_str()];
	}
	PrintToStdOut(context, output, actionContext->index);
	return true;
}

static id TreeNodeToObject(const TreeNode &node)
{
	NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:3];
	dict[@"name"] = @(node.name.c_str());
	dict[@"type"] = node.isDirectory ? @"directory" : @"file";
	if(node.isDirectory)
	{
		NSMutableArray *children = [NSMutableArray arrayWithCapacity:node.children.size()];
		for(const auto &child : node.children)
			[children addObject:TreeNodeToObject(child)];
		dict[@"children"] = children;
	}
	return dict;
}

bool
DirectoryTree(const char *dirPath, NSInteger maxDepth, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && (context->lastError.error != nil))
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[tree]\t%s\n", dirPath];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	actionContext->index++;

	if(context->dryRun)
	{
		ActionWithNoOutput(context, actionContext->index);
		return true;
	}

	TreeNode root;
	if(!build_directory_tree(dirPath, root, (int)maxDepth))
	{
		int err = errno;
		NSString *errStr = [NSString stringWithFormat:@"error: failed to read directory \"%s\": %s\n", dirPath, strerror(err)];
		PrintToStdErr(context, errStr);
		NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: errStr };
		context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:userInfo];
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	NSError *jsonError = nil;
	NSData *jsonData = [NSJSONSerialization dataWithJSONObject:TreeNodeToObject(root)
	                                                   options:0
	                                                     error:&jsonError];
	NSString *jsonStr = jsonData
		? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]
		: @"{}";

	NSString *output = [NSString stringWithFormat:@"[tree:%s]\n%@\n", dirPath, jsonStr];
	PrintToStdOut(context, output, actionContext->index);
	return true;
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

