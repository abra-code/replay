#include "ReplayAction.h"
#include "ReplayActionPrivate.h"
#include "ActionFromName.h"
#include "GlobOverlap.h"
#include "FileSystemHelpers.h"
#include <string>
#include <vector>


static inline std::function<void()>
CreateSourceDestinationAction(Action replayAction, std::string fromPath, std::string toPath, ReplayContext *context, ActionStep step, intptr_t actionIndex)
{
	if(fromPath.empty() || toPath.empty())
		return nullptr;

	std::function<void()> action;
	switch(replayAction)
	{
		case kFileActionClone:
		{
			action = [fromPath, toPath, context, step, actionIndex]() {
				ActionContext localContext = { .settings = step, .index = actionIndex };
				__unused bool isOK = CloneItem(fromPath, toPath, context, &localContext);
			};
		}
		break;

		case kFileActionMove:
		{
			action = [fromPath, toPath, context, step, actionIndex]() {
				ActionContext localContext = { .settings = step, .index = actionIndex };
				__unused bool isOK = MoveItem(fromPath, toPath, context, &localContext);
			};
		}
		break;

		case kFileActionHardlink:
		{
			action = [fromPath, toPath, context, step, actionIndex]() {
				ActionContext localContext = { .settings = step, .index = actionIndex };
				__unused bool isOK = HardlinkItem(fromPath, toPath, context, &localContext);
			};
		}
		break;

		case kFileActionSymlink:
		{
			action = [fromPath, toPath, context, step, actionIndex]() {
				ActionContext localContext = { .settings = step, .index = actionIndex };
				__unused bool isOK = SymlinkItem(fromPath, toPath, context, &localContext);
			};
		}
		break;

		default:
		break;
	}
	return action;
}

static inline std::vector<std::string>
GetExpandedPathsFromVector(const std::optional<std::vector<std::string>>& rawPaths, ReplayContext *context)
{
	std::vector<std::string> result;
	if(!rawPaths.has_value())
		return result;
	result.reserve(rawPaths->size());
	for(const auto& onePath : *rawPaths)
	{
		auto expanded = ExpandEnvVars(onePath.c_str(), context);
		if(expanded.has_value())
			result.push_back(std::move(*expanded));
	}
	return result;
}


// Resolves one playlist step and calls actionHandler one or more times.
// (A step may expand into multiple actions, e.g. copying a list of items to a directory.)
void
HandleActionStep(ActionStep step, ReplayContext *context, action_handler_t actionHandler)
{
	if(context->stopOnError && (context->lastError.hasError()))
		return;

	bool isSrcDestAction = false;
	Action replayAction = ActionFromName(step.string_value("action"), isSrcDestAction);

	if(replayAction == kActionInvalid)
		return;

	std::function<void()> action;
	std::vector<std::string> inputs;
	std::vector<std::string> mutatingInputs;
	std::vector<std::string> exclusiveInputs;
	std::vector<std::string> outputs;

	if(isSrcDestAction)
	{
		auto sourcePath = step.string_value("from");
		auto destinationPath = step.string_value("to");
		if(sourcePath.has_value() && destinationPath.has_value())
		{//simple one-to-one form
			auto expandedSource = ExpandEnvVars(sourcePath->c_str(), context);
			auto expandedDest = ExpandEnvVars(destinationPath->c_str(), context);
			if(!expandedSource.has_value() || !expandedDest.has_value())
			{
				actionHandler({}, {}, {}, {}, {});
			}
			else if(globoverlap::is_glob_pattern(*expandedSource))
			{
				// Glob source: expand at execution time, act on each match.
				// "to" is treated as destination directory (multiple sources to one dir).
				std::string globPattern = *expandedSource;
				std::string capturedDestDir = *expandedDest;
				intptr_t actionIndex = ++(context->actionCounter);
				Action capturedAction = replayAction;

				action = [globPattern, capturedDestDir, capturedAction, context, step, actionIndex]() {
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
						ActionContext localContext = { .settings = step, .index = actionIndex };
						switch(capturedAction) {
							case kFileActionClone:    CloneItem(match, destPath, context, &localContext); break;
							case kFileActionMove:     MoveItem(match, destPath, context, &localContext); break;
							case kFileActionHardlink: HardlinkItem(match, destPath, context, &localContext); break;
							default: break;
						}
					}
				};

				if(context->concurrent)
				{
					// The glob pattern is the input for dependency analysis
					if(replayAction == kFileActionMove)
						exclusiveInputs = {globPattern};
					else
						inputs = {globPattern};
					outputs = {capturedDestDir};
				}
				actionHandler(std::move(action), inputs, {}, exclusiveInputs, outputs);
			}
			else
			{
				// Concrete source path — original behavior
				std::string fromPath = *expandedSource;
				std::string toPath = *expandedDest;

				intptr_t actionIndex = ++(context->actionCounter);
				action = CreateSourceDestinationAction(replayAction, fromPath, toPath, context, step, actionIndex);

				if(context->concurrent)
				{
					if(replayAction == kFileActionMove)
						exclusiveInputs = {fromPath};
					else
						inputs = {fromPath};
					outputs = {toPath};
				}
				actionHandler(std::move(action), inputs, {}, exclusiveInputs, outputs);
			}
		}
		else
		{//multiple items to destination directory form
			auto itemPaths = step.string_array("items");
			auto destinationDirPath = step.string_value("destination directory");
			if(itemPaths.has_value() && destinationDirPath.has_value())
			{
				std::string capturedDestDir;
				auto expandedDestOpt = ExpandEnvVars(destinationDirPath->c_str(), context);
				if(expandedDestOpt.has_value())
					capturedDestDir = *expandedDestOpt;

				for(const auto& onePath : *itemPaths)
				{
					auto expandedOpt = ExpandEnvVars(onePath.c_str(), context);
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
						intptr_t actionIndex = ++(context->actionCounter);
						Action capturedAction = replayAction;

						action = [globPattern, capturedDestDir, capturedAction, context, step, actionIndex]() {
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
								ActionContext localContext = { .settings = step, .index = actionIndex };
								switch(capturedAction) {
									case kFileActionClone:    CloneItem(match, destPath, context, &localContext); break;
									case kFileActionMove:     MoveItem(match, destPath, context, &localContext); break;
									case kFileActionHardlink: HardlinkItem(match, destPath, context, &localContext); break;
									default: break;
								}
							}
						};

						inputs.clear(); exclusiveInputs.clear(); outputs.clear();
						if(context->concurrent)
						{
							if(replayAction == kFileActionMove)
								exclusiveInputs = {globPattern};
							else
								inputs = {globPattern};
							outputs = {capturedDestDir};
						}
						actionHandler(std::move(action), inputs, {}, exclusiveInputs, outputs);
					}
					else
					{
						// Concrete item — original behavior
						std::string srcPath = *expandedOpt;
						auto slash = srcPath.rfind('/');
						std::string fileName = (slash != std::string::npos) ? srcPath.substr(slash + 1) : srcPath;
						std::string dstPath = capturedDestDir + "/" + fileName;
						intptr_t actionIndex = ++(context->actionCounter);
						action = CreateSourceDestinationAction(replayAction, srcPath, dstPath, context, step, actionIndex);

						inputs.clear(); exclusiveInputs.clear(); outputs.clear();
						if(context->concurrent)
						{
							if(replayAction == kFileActionMove)
								exclusiveInputs = {srcPath};
							else
								inputs = {srcPath};
							outputs = {dstPath};
						}
						actionHandler(std::move(action), inputs, {}, exclusiveInputs, outputs);
					}
				}
			}
		}
	}
	else
	{
		if(replayAction == kFileActionDelete)
		{
			auto itemPaths = step.string_array("items");
			if(itemPaths.has_value())
			{
				for(const auto& onePath : *itemPaths)
				{
					auto expandedOpt = ExpandEnvVars(onePath.c_str(), context);
					if(expandedOpt.has_value())
					{
						if(globoverlap::is_glob_pattern(*expandedOpt))
						{
							// Glob item: expand at execution time, delete each match
							std::string globPattern = *expandedOpt;
							intptr_t actionIndex = ++(context->actionCounter);

							action = [globPattern, context, step, actionIndex]() {
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
									ActionContext localContext = { .settings = step, .index = actionIndex };
									__unused bool isOK = DeleteItem(match, context, &localContext);
								}
							};

							exclusiveInputs.clear();
							if(context->concurrent)
								exclusiveInputs = {globPattern};
							actionHandler(std::move(action), {}, {}, exclusiveInputs, {});
						}
						else
						{
							// Concrete item — original behavior
							std::string capturedPath = *expandedOpt;
							intptr_t actionIndex = ++(context->actionCounter);
							action = [capturedPath, context, step, actionIndex]() {
								ActionContext actionContext = { .settings = step, .index = actionIndex };
								__unused bool isOK = DeleteItem(capturedPath, context, &actionContext);
							};

							exclusiveInputs.clear();
							if(context->concurrent)
								exclusiveInputs = {capturedPath};
							actionHandler(std::move(action), {}, {}, exclusiveInputs, {});
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
			auto itemPaths = step.string_array("items");
			if(itemPaths.has_value())
			{
				for(const auto& onePath : *itemPaths)
				{
					auto expandedOpt = ExpandEnvVars(onePath.c_str(), context);
					if(expandedOpt.has_value())
					{
						std::string capturedPath = *expandedOpt;
						intptr_t actionIndex = ++(context->actionCounter);
						action = [capturedPath, context, step, actionIndex]() {
							ActionContext actionContext = { .settings = step, .index = actionIndex };
							__unused bool isOK = ReadFile(capturedPath, context, &actionContext);
						};
						// ReadFile prints two strings (verbose descriptor + content), reserve second slot
						++(context->actionCounter);

						inputs.clear();
						if(context->concurrent)
							inputs = {capturedPath};
						actionHandler(std::move(action), inputs, {}, {}, {});
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
			auto dirPath = step.string_value("directory");
			if(dirPath.has_value())
			{
				auto expandedOpt = ExpandEnvVars(dirPath->c_str(), context);
				if(expandedOpt.has_value())
				{
					std::string capturedPath = *expandedOpt;
					intptr_t actionIndex = ++(context->actionCounter);
					action = [capturedPath, context, step, actionIndex]() {
						ActionContext actionContext = { .settings = step, .index = actionIndex };
						__unused bool isOK = ListDirectory(capturedPath, context, &actionContext);
					};
					++(context->actionCounter);

					if(context->concurrent)
						inputs = {capturedPath};
					actionHandler(std::move(action), inputs, {}, {}, {});
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
			auto dirPath = step.string_value("directory");
			if(dirPath.has_value())
			{
				auto expandedOpt = ExpandEnvVars(dirPath->c_str(), context);
				if(expandedOpt.has_value())
				{
					std::string capturedPath = *expandedOpt;
					intptr_t capturedDepth = step.int_value("depth", 5);
					intptr_t actionIndex = ++(context->actionCounter);
					action = [capturedPath, capturedDepth, context, step, actionIndex]() {
						ActionContext actionContext = { .settings = step, .index = actionIndex };
						__unused bool isOK = DirectoryTree(capturedPath, capturedDepth, context, &actionContext);
					};
					++(context->actionCounter);

					if(context->concurrent)
						inputs = {capturedPath};
					actionHandler(std::move(action), inputs, {}, {}, {});
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
			auto filePath = step.string_value("path");
			if(filePath.has_value())
			{
				auto expandedOpt = ExpandEnvVars(filePath->c_str(), context);
				if(expandedOpt.has_value())
				{
					std::string capturedPath = *expandedOpt;
					intptr_t actionIndex = ++(context->actionCounter);
					action = [capturedPath, context, step, actionIndex]() {
						ActionContext actionContext = { .settings = step, .index = actionIndex };
						__unused bool isOK = GetFileInfo(capturedPath, context, &actionContext);
					};
					++(context->actionCounter);

					if(context->concurrent)
						inputs = {capturedPath};
					actionHandler(std::move(action), inputs, {}, {}, {});
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
			auto rawRootOpt = step.string_value("root");
			auto rawGlobsOpt = step.string_array("glob");

			if(rawRootOpt.has_value() && rawGlobsOpt.has_value() && !rawGlobsOpt->empty())
			{
				auto expandedRootOpt = ExpandEnvVars(rawRootOpt->c_str(), context);
				std::string capturedRoot = expandedRootOpt.has_value() ? *expandedRootOpt : *rawRootOpt;

				std::vector<std::string> capturedGlobs;
				for(const auto& p : *rawGlobsOpt)
				{
					auto ep = ExpandEnvVars(p.c_str(), context);
					if(ep.has_value())
						capturedGlobs.push_back(std::move(*ep));
				}

				auto rawExcludesOpt = step.string_array("exclude");
				std::vector<std::string> capturedExcludes;
				if(rawExcludesOpt.has_value())
				{
					for(const auto& p : *rawExcludesOpt)
					{
						auto ep = ExpandEnvVars(p.c_str(), context);
						if(ep.has_value())
							capturedExcludes.push_back(std::move(*ep));
					}
				}

				intptr_t capturedMax = step.int_value("max", 1000);
				intptr_t actionIndex = ++(context->actionCounter);
				action = [capturedRoot, capturedGlobs = std::move(capturedGlobs), capturedExcludes = std::move(capturedExcludes), capturedMax, context, step, actionIndex]() {
					ActionContext actionContext = { .settings = step, .index = actionIndex };
					__unused bool isOK = GlobFiles(capturedRoot, capturedGlobs, capturedExcludes, capturedMax, context, &actionContext);
				};
				++(context->actionCounter);

				if(context->concurrent)
					inputs = {capturedRoot};
				actionHandler(std::move(action), inputs, {}, {}, {});
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
			auto rawEditsOpt = step.step_array("edits");
			if(rawEditsOpt.has_value() && !rawEditsOpt->empty())
			{
				for(const auto& editStep : *rawEditsOpt)
				{
					auto oldTextOpt = editStep.string_value("oldText");
					if(!oldTextOpt.has_value())
						continue;
					FileEdit fe;
					fe.old_text = *oldTextOpt;
					fe.new_text = editStep.string_value("newText").value_or("");
					fe.limit = (int)editStep.int_value("limit", 1);
					fe.use_regex = editStep.bool_value("regex", false);
					fe.case_insensitive = editStep.bool_value("case-insensitive", false);
					editsVec.push_back(std::move(fe));
				}
				editsOK = !editsVec.empty();
			}
			else
			{
				// Simple streaming form: oldText/newText at top level
				auto oldTextOpt = step.string_value("oldText");
				if(oldTextOpt.has_value())
				{
					FileEdit fe;
					fe.old_text = *oldTextOpt;
					fe.new_text = step.string_value("newText").value_or("");
					fe.limit = (int)step.int_value("limit", 1);
					fe.use_regex = step.bool_value("regex", false);
					fe.case_insensitive = step.bool_value("case-insensitive", false);
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
				bool actionDryRun = step.bool_value("dry-run", false);

				auto itemPathsOpt = step.string_array("items");
				if(!itemPathsOpt.has_value() || itemPathsOpt->empty())
				{
					std::string errStr = "error: \"edit\" action: \"items\" array of paths is required\n";
					context->lastError.set(errStr, 1);
					PrintToStdErr(context, std::move(errStr));
					itemPathsOpt = std::nullopt;
				}

				if(itemPathsOpt.has_value())
				{
					for(const auto& onePath : *itemPathsOpt)
					{
						if(context->stopOnError && (context->lastError.hasError()))
							break;

						auto expandedOpt = ExpandEnvVars(onePath.c_str(), context);
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
							intptr_t actionIndex = ++(context->actionCounter);
							action = [globPattern, capturedEdits = std::move(capturedEdits), capturedDryRun, context, step, actionIndex]() {
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
									ActionContext actionContext = { .settings = step, .index = actionIndex };
									__unused bool isOK = EditFile(match, capturedEdits, capturedDryRun, context, &actionContext);
								}
							};
							++(context->actionCounter);

							mutatingInputs.clear();
							if(context->concurrent)
								mutatingInputs = {globPattern};
							actionHandler(std::move(action), {}, mutatingInputs, {}, {});
						}
						else
						{
							// Concrete path: one task per file (tasks are independent, can run in parallel)
							std::string capturedPath = *expandedOpt;
							std::vector<FileEdit> capturedEdits = editsVec;
							bool capturedDryRun = actionDryRun;
							intptr_t actionIndex = ++(context->actionCounter);
							action = [capturedPath, capturedEdits = std::move(capturedEdits), capturedDryRun, context, step, actionIndex]() {
								ActionContext actionContext = { .settings = step, .index = actionIndex };
								__unused bool isOK = EditFile(capturedPath, capturedEdits, capturedDryRun, context, &actionContext);
							};
							++(context->actionCounter);

							mutatingInputs.clear();
							if(context->concurrent)
								mutatingInputs = {capturedPath};
							actionHandler(std::move(action), {}, mutatingInputs, {}, {});
						}
					}
				}
			}
		}
		else if(replayAction == kFileActionCreate)
		{
			auto filePathOpt = step.string_value("file");
			if(filePathOpt.has_value())
			{
				// blob (base64 binary) takes priority over text content
				auto blobStrOpt = step.string_value("blob");
				std::string blobContent;
				bool isBlob = false;

				if(blobStrOpt.has_value())
				{
					// JSON/plist format: "blob": "<base64>" key holds the data
					blobContent = *blobStrOpt;
					isBlob = true;
				}
				else if(step.bool_value("blob", false))
				{
					// streaming format: blob=true modifier, "content" holds the base64 data
					auto contentOpt = step.string_value("content");
					if(contentOpt.has_value())
					{
						blobContent = *contentOpt;
						isBlob = true;
					}
				}

				if(isBlob)
				{
					auto pathOpt = ExpandEnvVars(filePathOpt->c_str(), context);
					if(pathOpt.has_value())
					{
						std::string capturedPath = *pathOpt;
						std::string capturedBlob = blobContent;
						intptr_t actionIndex = ++(context->actionCounter);
						action = [capturedPath, capturedBlob, context, step, actionIndex]() {
							ActionContext actionContext = { .settings = step, .index = actionIndex };
							__unused bool isOK = CreateFileFromBlob(capturedPath, capturedBlob, context, &actionContext);
						};
						if(context->concurrent)
							outputs = {capturedPath};
						actionHandler(std::move(action), {}, {}, {}, outputs);
					}
				}
				else
				{
					std::string contentStr = step.string_value("content").value_or("");
					bool expandContent = !step.bool_value("raw", false);

					std::string capturedContent;
					bool contentOK = true;
					if(expandContent)
					{
						auto contentOpt = ExpandEnvVars(contentStr.c_str(), context);
						if(!contentOpt.has_value())
							contentOK = false;
						else
							capturedContent = *contentOpt;
					}
					else
					{
						capturedContent = contentStr;
					}

					auto pathOpt = ExpandEnvVars(filePathOpt->c_str(), context);

					// contentOK is false only if string is malformed or missing environment variable
					if(contentOK && pathOpt.has_value())
					{
						std::string capturedPath = *pathOpt;
						intptr_t actionIndex = ++(context->actionCounter);
						action = [capturedPath, capturedContent, context, step, actionIndex]() {
							ActionContext actionContext = { .settings = step, .index = actionIndex };
							__unused bool isOK = CreateFile(capturedPath, capturedContent, context, &actionContext);
						};

						if(context->concurrent)
							outputs = {capturedPath};
						actionHandler(std::move(action), {}, {}, {}, outputs);
					}
				}
			}
			else
			{
				auto dirPathOpt = step.string_value("directory");
				if(dirPathOpt.has_value())
				{
					auto pathOpt = ExpandEnvVars(dirPathOpt->c_str(), context);
					if(pathOpt.has_value())
					{
						std::string capturedPath = *pathOpt;
						intptr_t actionIndex = ++(context->actionCounter);
						action = [capturedPath, context, step, actionIndex]() {
							ActionContext actionContext = { .settings = step, .index = actionIndex };
							__unused bool isOK = CreateDirectory(capturedPath, context, &actionContext);
						};

						if(context->concurrent)
							outputs = {capturedPath};
						actionHandler(std::move(action), {}, {}, {}, outputs);
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
			auto toolPathOpt = step.string_value("tool");
			if(toolPathOpt.has_value())
			{
				auto expandedToolOpt = ExpandEnvVars(toolPathOpt->c_str(), context);
				if(expandedToolOpt.has_value())
				{
					bool argsOK = true;
					std::vector<std::string> capturedArgs;
					auto argumentsOpt = step.string_array("arguments");
					if(argumentsOpt.has_value())
					{
						capturedArgs.reserve(argumentsOpt->size());
						for(const auto& oneArg : *argumentsOpt)
						{
							auto expandedArgOpt = ExpandEnvVars(oneArg.c_str(), context);
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
					}

					if(argsOK)
					{
						std::string capturedToolPath = *expandedToolOpt;
						intptr_t actionIndex = ++(context->actionCounter);
						action = [capturedToolPath, capturedArgs = std::move(capturedArgs), context, step, actionIndex]() {
							ActionContext actionContext = { .settings = step, .index = actionIndex };
							__unused bool isOK = ExcecuteTool(capturedToolPath, capturedArgs, context, &actionContext);
						};

						// [execute] action is expected to print two strings:
						// - verbose action description (or null string if not verbose)
						// - stdout from child tool (or null string if stdout is suppressed)
						// so we need to increase the counter second time
						++(context->actionCounter);

						if(context->concurrent)
						{
							inputs = GetExpandedPathsFromVector(step.string_array("inputs"), context);
							exclusiveInputs = GetExpandedPathsFromVector(step.string_array("exclusive inputs"), context);
							outputs = GetExpandedPathsFromVector(step.string_array("outputs"), context);
						}

						actionHandler(std::move(action), inputs, {}, exclusiveInputs, outputs);
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
			std::string textStr = step.string_value("text").value_or("");
			bool expandText = !step.bool_value("raw", false);

			std::string capturedText;
			bool textOK = true;
			if(expandText)
			{
				auto expandedOpt = ExpandEnvVars(textStr.c_str(), context);
				if(!expandedOpt.has_value())
					textOK = false;
				else
					capturedText = *expandedOpt;
			}
			else
			{
				capturedText = textStr;
			}

			// capturedText is empty (textOK=false) only if string is malformed or missing environment variable
			if(textOK)
			{
				intptr_t actionIndex = ++(context->actionCounter);
				action = [capturedText, context, step, actionIndex]() {
					ActionContext actionContext = { .settings = step, .index = actionIndex };
					__unused bool isOK = Echo(capturedText, context, &actionContext);
				};

				// [echo] action is expected to print two strings:
				// - verbose action description (or null string if not verbose)
				// - actual text printed to stdout
				// so we need to increase the counter second time
				++(context->actionCounter);

				actionHandler(std::move(action), {}, {}, {}, {});
			}
		}
		else if((replayAction == kActionWait) || (replayAction == kActionStartServer))
		{
			// we should never arrive here with this pseudo-action
			assert((replayAction != kActionWait) && (replayAction != kActionStartServer));
		}
	}
}
