#include "ReplayAction.h"
#include "ReplayActionPrivate.h"
#include "ActionFromName.h"
#include "GlobOverlap.h"
#include "FileSystemHelpers.h"
#include "ABase64.h"
#include "blake3.h"
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>


// Extras strings are composed of length-prefixed components (8-byte little-endian
// length followed by the raw bytes) so no concatenation of components can collide
// with a different split into other components. A collision here would be a wrong
// cache skip (two different tasks sharing one signature), never just a miss.
static inline void
AppendExtrasComponent(std::string &extras, std::string_view component)
{
	uint64_t length = component.size();
	for(int shift = 0; shift < 64; shift += 8)
	{
		extras.push_back((char)((length >> shift) & 0xff));
	}
	extras.append(component);
}

static inline std::string
Blake3Hex(const void *bytes, size_t length)
{
	blake3_hasher hasher;
	blake3_hasher_init(&hasher);
	blake3_hasher_update(&hasher, bytes, length);
	uint8_t digest[BLAKE3_OUT_LEN];
	blake3_hasher_finalize(&hasher, digest, sizeof(digest));
	static const char hexDigits[] = "0123456789abcdef";
	std::string result;
	result.reserve(2 * sizeof(digest));
	for(uint8_t oneByte : digest)
	{
		result.push_back(hexDigits[oneByte >> 4]);
		result.push_back(hexDigits[oneByte & 0x0f]);
	}
	return result;
}

// Cache identity beyond the path vectors for the source/destination action family.
// Only symlink has one: the "validate" flag changes behavior for the same from/to.
static inline std::string
SourceDestinationExtras(Action replayAction, const ActionStep &step)
{
	std::string extras;
	if(replayAction == kFileActionSymlink)
	{
		AppendExtrasComponent(extras, step.bool_value("validate", true) ? "1" : "0");
	}
	return extras;
}

static inline std::function<bool()>
CreateSourceDestinationAction(Action replayAction, std::string fromPath, std::string toPath, ReplayContext *context, ActionStep step, intptr_t actionIndex)
{
	if(fromPath.empty() || toPath.empty())
		return nullptr;

	std::function<bool()> action;
	switch(replayAction)
	{
		case kFileActionClone:
		{
			action = [fromPath, toPath, context, step, actionIndex]() -> bool {
				ActionContext localContext = { .settings = step, .index = actionIndex };
				return CloneItem(fromPath, toPath, context, &localContext);
			};
		}
		break;

		case kFileActionMove:
		{
			action = [fromPath, toPath, context, step, actionIndex]() -> bool {
				ActionContext localContext = { .settings = step, .index = actionIndex };
				return MoveItem(fromPath, toPath, context, &localContext);
			};
		}
		break;

		case kFileActionHardlink:
		{
			action = [fromPath, toPath, context, step, actionIndex]() -> bool {
				ActionContext localContext = { .settings = step, .index = actionIndex };
				return HardlinkItem(fromPath, toPath, context, &localContext);
			};
		}
		break;

		case kFileActionSymlink:
		{
			action = [fromPath, toPath, context, step, actionIndex]() -> bool {
				ActionContext localContext = { .settings = step, .index = actionIndex };
				return SymlinkItem(fromPath, toPath, context, &localContext);
			};
		}
		break;

		default:
		break;
	}
	return action;
}

// An entry whose ${VAR} expansion fails is dropped from the result (ExpandEnvVars has
// already set lastError). outAnyDropped reports that, because a partially expanded
// declaration must never be cached: the surviving paths look like the action's complete
// world, so the dropped one is invisible to both the input fingerprint and the owned-path
// rollup, and every later change to it would be a wrong skip. stopOnError is off by
// default, so the step really does still run and really would store such an entry.
static inline std::vector<std::string>
GetExpandedPathsFromVector(const std::optional<std::vector<std::string>>& rawPaths, ReplayContext *context, bool *outAnyDropped = nullptr)
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
		else if(outAnyDropped != nullptr)
			*outAnyDropped = true;
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

	// Step-level cache identity material, shared by every action this step expands to.
	// Declared "env" names are validated eagerly: a missing variable is an action
	// error, the same strict policy ExpandEnvVars applies to ${VAR} references.
	ActionCacheInfo cacheInfo;
	if(step.string_value("env").has_value())
	{
		// A lone string here is a typo for the array form; silently ignoring it
		// would mean silently not folding the variable into the fingerprint.
		std::string errStr = "error: \"env\" is expected to be an array of environment variable names\n";
		context->lastError.set(errStr, 1);
		PrintToStdErr(context, std::move(errStr));
		return;
	}
	auto declaredEnvOpt = step.string_array("env");
	if(declaredEnvOpt.has_value())
	{
		for(const auto& oneName : *declaredEnvOpt)
		{
			if(context->environment.find(oneName) == context->environment.end())
			{
				std::string errStr = std::string("error: \"env\" array refers to environment variable \"") + oneName + "\" which is not defined\n";
				context->lastError.set(errStr, 1);
				PrintToStdErr(context, std::move(errStr));
				return;
			}
		}
		cacheInfo.envNames = std::move(*declaredEnvOpt);
	}

	// Optional per-step "cache" override: false opts a cacheable action out; true on
	// a non-cacheable action is accepted and ignored, with a one-time verbose note.
	// Presence is detected by the fallback value surviving both lookups. A string
	// value ("cache": "false") would survive both lookups too and silently leave
	// caching enabled, so it is rejected outright.
	if(step.string_value("cache").has_value())
	{
		std::string errStr = "error: \"cache\" is expected to be a boolean value\n";
		context->lastError.set(errStr, 1);
		PrintToStdErr(context, std::move(errStr));
		return;
	}
	bool cacheAllowed = step.bool_value("cache", true);
	bool cacheKeyPresent = (cacheAllowed == step.bool_value("cache", false));
	bool cacheNoteEmitted = false;

	// Every actionHandler invocation goes through this adapter: it merges the
	// per-action cache identity (cacheable, extras, existence-only outputs) with the
	// step-level material (envNames, "cache" override) into the final ActionCacheInfo.
	auto emitAction = [&](std::function<bool()> actionFn,
		std::vector<std::string> actionInputs,
		std::vector<std::string> actionMutatingInputs,
		std::vector<std::string> actionExclusiveInputs,
		std::vector<std::string> actionOutputs,
		bool cacheable,
		std::string extras = std::string(),
		bool outputsExistenceOnly = false)
	{
		if(!cacheable && cacheKeyPresent && cacheAllowed && context->cacheEnabled && context->verbose && !cacheNoteEmitted)
		{
			cacheNoteEmitted = true;
			std::string noteStr = std::string("note: \"cache\": true is ignored, action \"") + step.string_value("action").value_or("") + "\" is not cacheable\n";
			PrintToStdErr(context, std::move(noteStr));
		}
		ActionCacheInfo oneInfo = cacheInfo;
		oneInfo.cacheable = cacheable && cacheAllowed;
		oneInfo.extras = std::move(extras);
		oneInfo.outputsExistenceOnly = outputsExistenceOnly;
		actionHandler(std::move(actionFn), std::move(actionInputs), std::move(actionMutatingInputs), std::move(actionExclusiveInputs), std::move(actionOutputs), std::move(oneInfo));
	};

	std::function<bool()> action;
	std::vector<std::string> inputs;
	std::vector<std::string> mutatingInputs;
	std::vector<std::string> exclusiveInputs;
	std::vector<std::string> outputs;

	if(isSrcDestAction)
	{
		// All source/destination actions are cacheable. Move relies on the fixed-point
		// semantics of exclusive inputs: its recorded world_out has the source absent
		// and the destination present, which is exactly what the check reproduces
		// while nothing has changed (design 4.1/4.2).
		bool srcDestCacheable = true;
		// The glob fan-out loop below handles clone/move/hardlink only; a glob-source
		// symlink is a silent no-op today, and a no-op must never earn a cache entry.
		bool globSrcDestCacheable = (replayAction != kFileActionSymlink);

		auto sourcePath = step.string_value("from");
		auto destinationPath = step.string_value("to");
		if(sourcePath.has_value() && destinationPath.has_value())
		{//simple one-to-one form
			auto expandedSource = ExpandEnvVars(sourcePath->c_str(), context);
			auto expandedDest = ExpandEnvVars(destinationPath->c_str(), context);
			if(!expandedSource.has_value() || !expandedDest.has_value())
			{
				emitAction({}, {}, {}, {}, {}, false);
			}
			else if(globoverlap::is_glob_pattern(*expandedSource))
			{
				// Glob source: expand at execution time, act on each match.
				// "to" is treated as destination directory (multiple sources to one dir).
				std::string globPattern = *expandedSource;
				std::string capturedDestDir = *expandedDest;
				intptr_t actionIndex = ++(context->actionCounter);
				Action capturedAction = replayAction;

				action = [globPattern, capturedDestDir, capturedAction, context, step, actionIndex]() -> bool {
					auto matches = expand_glob(globPattern);
					if(matches.empty())
					{
						std::string errStr = std::string("error: glob pattern \"") + globPattern + "\" matched no files\n";
						context->lastError.set(errStr, 1);
						PrintToStdErr(context, std::move(errStr));
						return false;
					}
					bool allOK = true;
					for(const auto& match : matches)
					{
						if(context->stopOnError && (context->lastError.hasError()))
						{ // remaining matches were not processed - this action did not complete
							allOK = false;
							break;
						}
						auto slash = match.rfind('/');
						std::string fileName = (slash != std::string::npos) ? match.substr(slash + 1) : match;
						std::string destPath = capturedDestDir + "/" + fileName;
						ActionContext localContext = { .settings = step, .index = actionIndex };
						bool isOK = true;
						switch(capturedAction) {
							case kFileActionClone:    isOK = CloneItem(match, destPath, context, &localContext); break;
							case kFileActionMove:     isOK = MoveItem(match, destPath, context, &localContext); break;
							case kFileActionHardlink: isOK = HardlinkItem(match, destPath, context, &localContext); break;
							default: break;
						}
						if(!isOK)
							allOK = false;
					}
					return allOK;
				};

				if(context->concurrent || context->cacheEnabled)
				{
					// The glob pattern is the input for dependency analysis
					if(replayAction == kFileActionMove)
						exclusiveInputs = {globPattern};
					else
						inputs = {globPattern};
					outputs = {capturedDestDir};
				}
				emitAction(std::move(action), inputs, {}, exclusiveInputs, outputs, globSrcDestCacheable, SourceDestinationExtras(replayAction, step));
			}
			else
			{
				// Concrete source path — original behavior
				std::string fromPath = *expandedSource;
				std::string toPath = *expandedDest;

				intptr_t actionIndex = ++(context->actionCounter);
				action = CreateSourceDestinationAction(replayAction, fromPath, toPath, context, step, actionIndex);

				if(context->concurrent || context->cacheEnabled)
				{
					if(replayAction == kFileActionMove)
						exclusiveInputs = {fromPath};
					else
						inputs = {fromPath};
					outputs = {toPath};
				}
				emitAction(std::move(action), inputs, {}, exclusiveInputs, outputs, srcDestCacheable, SourceDestinationExtras(replayAction, step));
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

						action = [globPattern, capturedDestDir, capturedAction, context, step, actionIndex]() -> bool {
							auto matches = expand_glob(globPattern);
							if(matches.empty())
							{
								std::string errStr = std::string("error: glob pattern \"") + globPattern + "\" matched no files\n";
								context->lastError.set(errStr, 1);
								PrintToStdErr(context, std::move(errStr));
								return false;
							}
							bool allOK = true;
							for(const auto& match : matches)
							{
								if(context->stopOnError && (context->lastError.hasError()))
								{ // remaining matches were not processed - this action did not complete
									allOK = false;
									break;
								}
								auto slash = match.rfind('/');
								std::string fileName = (slash != std::string::npos) ? match.substr(slash + 1) : match;
								std::string destPath = capturedDestDir + "/" + fileName;
								ActionContext localContext = { .settings = step, .index = actionIndex };
								bool isOK = true;
								switch(capturedAction) {
									case kFileActionClone:    isOK = CloneItem(match, destPath, context, &localContext); break;
									case kFileActionMove:     isOK = MoveItem(match, destPath, context, &localContext); break;
									case kFileActionHardlink: isOK = HardlinkItem(match, destPath, context, &localContext); break;
									default: break;
								}
								if(!isOK)
									allOK = false;
							}
							return allOK;
						};

						inputs.clear(); exclusiveInputs.clear(); outputs.clear();
						if(context->concurrent || context->cacheEnabled)
						{
							if(replayAction == kFileActionMove)
								exclusiveInputs = {globPattern};
							else
								inputs = {globPattern};
							outputs = {capturedDestDir};
						}
						emitAction(std::move(action), inputs, {}, exclusiveInputs, outputs, globSrcDestCacheable, SourceDestinationExtras(replayAction, step));
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
						if(context->concurrent || context->cacheEnabled)
						{
							if(replayAction == kFileActionMove)
								exclusiveInputs = {srcPath};
							else
								inputs = {srcPath};
							outputs = {dstPath};
						}
						emitAction(std::move(action), inputs, {}, exclusiveInputs, outputs, srcDestCacheable, SourceDestinationExtras(replayAction, step));
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

							action = [globPattern, context, step, actionIndex]() -> bool {
								auto matches = expand_glob(globPattern);
								if(matches.empty())
								{
									std::string errStr = std::string("error: glob pattern \"") + globPattern + "\" matched no files\n";
									context->lastError.set(errStr, 1);
									PrintToStdErr(context, std::move(errStr));
									return false;
								}
								bool allOK = true;
								for(const auto& match : matches)
								{
									if(context->stopOnError && (context->lastError.hasError()))
									{ // remaining matches were not processed - this action did not complete
										allOK = false;
										break;
									}
									ActionContext localContext = { .settings = step, .index = actionIndex };
									if(!DeleteItem(match, context, &localContext))
										allOK = false;
								}
								return allOK;
							};

							exclusiveInputs.clear();
							if(context->concurrent || context->cacheEnabled)
								exclusiveInputs = {globPattern};
							emitAction(std::move(action), {}, {}, exclusiveInputs, {}, true);
						}
						else
						{
							// Concrete item — original behavior
							std::string capturedPath = *expandedOpt;
							intptr_t actionIndex = ++(context->actionCounter);
							action = [capturedPath, context, step, actionIndex]() -> bool {
								ActionContext actionContext = { .settings = step, .index = actionIndex };
								return DeleteItem(capturedPath, context, &actionContext);
							};

							exclusiveInputs.clear();
							if(context->concurrent || context->cacheEnabled)
								exclusiveInputs = {capturedPath};
							emitAction(std::move(action), {}, {}, exclusiveInputs, {}, true);
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
						action = [capturedPath, context, step, actionIndex]() -> bool {
							ActionContext actionContext = { .settings = step, .index = actionIndex };
							return ReadFile(capturedPath, context, &actionContext);
						};
						// ReadFile prints two strings (verbose descriptor + content), reserve second slot
						++(context->actionCounter);

						inputs.clear();
						if(context->concurrent || context->cacheEnabled)
							inputs = {capturedPath};
						emitAction(std::move(action), inputs, {}, {}, {}, false);
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
					action = [capturedPath, context, step, actionIndex]() -> bool {
						ActionContext actionContext = { .settings = step, .index = actionIndex };
						return ListDirectory(capturedPath, context, &actionContext);
					};
					++(context->actionCounter);

					if(context->concurrent || context->cacheEnabled)
						inputs = {capturedPath};
					emitAction(std::move(action), inputs, {}, {}, {}, false);
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
					action = [capturedPath, capturedDepth, context, step, actionIndex]() -> bool {
						ActionContext actionContext = { .settings = step, .index = actionIndex };
						return DirectoryTree(capturedPath, capturedDepth, context, &actionContext);
					};
					++(context->actionCounter);

					if(context->concurrent || context->cacheEnabled)
						inputs = {capturedPath};
					emitAction(std::move(action), inputs, {}, {}, {}, false);
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
					action = [capturedPath, context, step, actionIndex]() -> bool {
						ActionContext actionContext = { .settings = step, .index = actionIndex };
						return GetFileInfo(capturedPath, context, &actionContext);
					};
					++(context->actionCounter);

					if(context->concurrent || context->cacheEnabled)
						inputs = {capturedPath};
					emitAction(std::move(action), inputs, {}, {}, {}, false);
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
				action = [capturedRoot, capturedGlobs = std::move(capturedGlobs), capturedExcludes = std::move(capturedExcludes), capturedMax, context, step, actionIndex]() -> bool {
					ActionContext actionContext = { .settings = step, .index = actionIndex };
					return GlobFiles(capturedRoot, capturedGlobs, capturedExcludes, capturedMax, context, &actionContext);
				};
				++(context->actionCounter);

				if(context->concurrent || context->cacheEnabled)
					inputs = {capturedRoot};
				emitAction(std::move(action), inputs, {}, {}, {}, false);
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

				// Cache identity of the edit operations, shared by every item task.
				// Each op contributes exactly five components, plus one trailing
				// dry-run component, so the flat sequence is unambiguous.
				std::string editExtras;
				for(const auto& oneEdit : editsVec)
				{
					AppendExtrasComponent(editExtras, oneEdit.old_text);
					AppendExtrasComponent(editExtras, oneEdit.new_text);
					AppendExtrasComponent(editExtras, std::to_string(oneEdit.limit));
					AppendExtrasComponent(editExtras, oneEdit.use_regex ? "1" : "0");
					AppendExtrasComponent(editExtras, oneEdit.case_insensitive ? "1" : "0");
				}
				AppendExtrasComponent(editExtras, actionDryRun ? "1" : "0");

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
							action = [globPattern, capturedEdits = std::move(capturedEdits), capturedDryRun, context, step, actionIndex]() -> bool {
								auto matches = expand_glob(globPattern);
								if(matches.empty())
								{
									std::string errStr = std::string("error: glob pattern \"") + globPattern + "\" matched no files\n";
									context->lastError.set(errStr, 1);
									PrintToStdErr(context, std::move(errStr));
									return false;
								}
								bool allOK = true;
								for(const auto& match : matches)
								{
									if(context->stopOnError && (context->lastError.hasError()))
									{ // remaining matches were not processed - this action did not complete
										allOK = false;
										break;
									}
									ActionContext actionContext = { .settings = step, .index = actionIndex };
									if(!EditFile(match, capturedEdits, capturedDryRun, context, &actionContext))
										allOK = false;
								}
								return allOK;
							};
							++(context->actionCounter);

							mutatingInputs.clear();
							if(context->concurrent || context->cacheEnabled)
								mutatingInputs = {globPattern};
							// An edit with "dry-run": true is a stdout action and never cacheable.
							emitAction(std::move(action), {}, mutatingInputs, {}, {}, !actionDryRun, editExtras);
						}
						else
						{
							// Concrete path: one task per file (tasks are independent, can run in parallel)
							std::string capturedPath = *expandedOpt;
							std::vector<FileEdit> capturedEdits = editsVec;
							bool capturedDryRun = actionDryRun;
							intptr_t actionIndex = ++(context->actionCounter);
							action = [capturedPath, capturedEdits = std::move(capturedEdits), capturedDryRun, context, step, actionIndex]() -> bool {
								ActionContext actionContext = { .settings = step, .index = actionIndex };
								return EditFile(capturedPath, capturedEdits, capturedDryRun, context, &actionContext);
							};
							++(context->actionCounter);

							mutatingInputs.clear();
							if(context->concurrent || context->cacheEnabled)
								mutatingInputs = {capturedPath};
							// An edit with "dry-run": true is a stdout action and never cacheable.
							emitAction(std::move(action), {}, mutatingInputs, {}, {}, !actionDryRun, editExtras);
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
						action = [capturedPath, capturedBlob, context, step, actionIndex]() -> bool {
							ActionContext actionContext = { .settings = step, .index = actionIndex };
							return CreateFileFromBlob(capturedPath, capturedBlob, context, &actionContext);
						};

						// Cache identity is the hash of the DECODED bytes (what lands in the
						// file), so a re-encoding of identical data still hits. Decode failure
						// mirrors the action: zero bytes decoded means an empty file is written.
						// Only when the cache is on: this decodes the blob a second time (the
						// action decodes it again when it runs) and allocates the full decoded
						// size, which is pure waste on the default non-caching path for a
						// playlist that embeds large assets.
						std::string blobExtras;
						if(context->cacheEnabled)
						{
							unsigned long encodedLen = (unsigned long)capturedBlob.size();
							unsigned long maxDecoded = CalculateDecodedBufferMaxSize(encodedLen);
							std::vector<unsigned char> decoded(maxDecoded > 0 ? maxDecoded : 1);
							unsigned long decodedLen = encodedLen > 0
								? DecodeBase64((const unsigned char *)capturedBlob.c_str(), encodedLen, decoded.data(), maxDecoded)
								: 0;
							AppendExtrasComponent(blobExtras, Blake3Hex(decoded.data(), decodedLen));
							AppendExtrasComponent(blobExtras, "blob");
						}

						if(context->concurrent || context->cacheEnabled)
							outputs = {capturedPath};
						emitAction(std::move(action), {}, {}, {}, outputs, true, std::move(blobExtras));
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
						action = [capturedPath, capturedContent, context, step, actionIndex]() -> bool {
							ActionContext actionContext = { .settings = step, .index = actionIndex };
							return CreateFile(capturedPath, capturedContent, context, &actionContext);
						};

						// The captured (post-expansion) content identifies the product; the raw
						// flag distinguishes text whose expansion happens to be the identity.
						std::string fileExtras;
						AppendExtrasComponent(fileExtras, Blake3Hex(capturedContent.data(), capturedContent.size()));
						AppendExtrasComponent(fileExtras, expandContent ? "0" : "1");

						if(context->concurrent || context->cacheEnabled)
							outputs = {capturedPath};
						emitAction(std::move(action), {}, {}, {}, outputs, true, std::move(fileExtras));
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
						action = [capturedPath, context, step, actionIndex]() -> bool {
							ActionContext actionContext = { .settings = step, .index = actionIndex };
							return CreateDirectory(capturedPath, context, &actionContext);
						};

						if(context->concurrent || context->cacheEnabled)
							outputs = {capturedPath};
						// Other tasks legitimately write into a created directory later, so
						// its up-to-date check is existence + type only, never content.
						emitAction(std::move(action), {}, {}, {}, outputs, true, std::string(), true);
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

						// The expanded command line is the action's cache identity beyond
						// its declared paths.
						std::string executeExtras;
						AppendExtrasComponent(executeExtras, capturedToolPath);
						for(const auto& oneArg : capturedArgs)
						{
							AppendExtrasComponent(executeExtras, oneArg);
						}

						intptr_t actionIndex = ++(context->actionCounter);
						action = [capturedToolPath, capturedArgs = std::move(capturedArgs), context, step, actionIndex]() -> bool {
							ActionContext actionContext = { .settings = step, .index = actionIndex };
							return ExcecuteTool(capturedToolPath, capturedArgs, context, &actionContext);
						};

						// [execute] action is expected to print two strings:
						// - verbose action description (or null string if not verbose)
						// - stdout from child tool (or null string if stdout is suppressed)
						// so we need to increase the counter second time
						++(context->actionCounter);

						bool anyPathDropped = false;
						if(context->concurrent || context->cacheEnabled)
						{
							inputs = GetExpandedPathsFromVector(step.string_array("inputs"), context, &anyPathDropped);
							exclusiveInputs = GetExpandedPathsFromVector(step.string_array("exclusive inputs"), context, &anyPathDropped);
							outputs = GetExpandedPathsFromVector(step.string_array("outputs"), context, &anyPathDropped);
						}

						// An execute without declared outputs has unknown side effects and
						// must always run (design 4.2). Neither may one whose declaration
						// only partly expanded: the paths that survived would masquerade as
						// the action's whole world.
						emitAction(std::move(action), inputs, {}, exclusiveInputs, outputs,
							!outputs.empty() && !anyPathDropped, std::move(executeExtras));
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
				action = [capturedText, context, step, actionIndex]() -> bool {
					ActionContext actionContext = { .settings = step, .index = actionIndex };
					return Echo(capturedText, context, &actionContext);
				};

				// [echo] action is expected to print two strings:
				// - verbose action description (or null string if not verbose)
				// - actual text printed to stdout
				// so we need to increase the counter second time
				++(context->actionCounter);

				emitAction(std::move(action), {}, {}, {}, {}, false);
			}
		}
		else if((replayAction == kActionWait) || (replayAction == kActionStartServer))
		{
			// we should never arrive here with this pseudo-action
			assert((replayAction != kActionWait) && (replayAction != kActionStartServer));
		}
	}
}
