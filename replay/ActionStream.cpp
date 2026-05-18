//
//  ActionStream.cpp
//
//  Created by Tomasz Kukielka on 12/26/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#include "ActionStream.h"
#include "OutputSerializer.h"
#include "ReplayServer.h"
#include "ConcurrentDispatchWithNoDependency.h"
#include "SerialDispatch.h"
#include "ActionFromName.h"
#include "CFObj.h"
#include <CoreFoundation/CoreFoundation.h>
#include <cstring>
#include <string_view>
#include <vector>
#include <algorithm>

void
StartReceivingActions(ReplayContext *context)
{
	if(context->concurrent)
	{
		context->actionCounter = -1;
		context->analyzeDependencies = false; // building dependency graph is not supported when tasks are streamed
		StartConcurrentDispatchWithNoDependency(context);
	}
	else
	{
		context->actionCounter = -1;
		context->orderedOutput = false;
		StartSerialDispatch(context);
	}
}

void
FinishReceivingActionsAndWait(ReplayContext *context)
{
	if(context->concurrent)
		FinishConcurrentDispatchWithNoDependencyAndWait(context);
	else
		FinishSerialDispatchAndWait(context);

	context->outputSerializer->flush();
}

// ---------------------------------------------------------------------------
// Line-parsing helpers
// ---------------------------------------------------------------------------

static inline CFObj<CFStringRef>
MakeCFStr(std::string_view sv)
{
	return CFObj<CFStringRef>(CFStringCreateWithBytes(kCFAllocatorDefault,
		(const UInt8*)sv.data(), (CFIndex)sv.size(), kCFStringEncodingUTF8, false));
}

// Split str by sep into a vector of string_view substrings.
// Each element references memory inside str — no copies.
static std::vector<std::string_view>
SplitSV(std::string_view str, char sep)
{
	std::vector<std::string_view> result;
	size_t start = 0;
	for(size_t i = 0; i <= str.size(); i++)
	{
		if(i == str.size() || str[i] == (unsigned char)sep)
		{
			result.push_back(str.substr(start, i - start));
			start = i + 1;
		}
	}
	return result;
}

// Build a CFMutableArrayRef of CFStringRef values from a span of string_views.
static CFObj<CFMutableArrayRef>
CFArrayFromSVs(const std::vector<std::string_view>& items, size_t startIdx = 0)
{
	CFIndex count = (CFIndex)(items.size() > startIdx ? items.size() - startIdx : 0);
	CFObj<CFMutableArrayRef> arr(CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks));
	for(size_t i = startIdx; i < items.size(); i++)
	{
		CFObj<CFStringRef> s = MakeCFStr(items[i]);
		CFArrayAppendValue(arr, s);
	}
	return arr;
}

// Parse key=value option tokens (starting at index 1) into the dict.
// Boolean true/false (case-insensitive), integers, and string values are supported.
static void
AddOptionsToActionDescription(CFMutableDictionaryRef dict, const std::vector<std::string_view>& aoTokens)
{
	for(size_t i = 1; i < aoTokens.size(); i++)
	{
		std::string_view opt = aoTokens[i];
		auto eq = opt.find('=');
		if(eq == std::string_view::npos)
			continue;

		std::string_view key = opt.substr(0, eq);
		std::string_view val = opt.substr(eq + 1);
		if(key.empty())
			continue;

		CFObj<CFStringRef> cfKey = MakeCFStr(key);
		if(cfKey == NULL)
			continue;

		if(strncasecmp(val.data(), "true", val.size()) == 0 && val.size() == 4)
		{
			CFDictionarySetValue(dict, cfKey, kCFBooleanTrue);
		}
		else if(strncasecmp(val.data(), "false", val.size()) == 0 && val.size() == 5)
		{
			CFDictionarySetValue(dict, cfKey, kCFBooleanFalse);
		}
		else
		{
			// Try integer parse; fall back to string.
			char numBuf[32];
			bool isInt = false;
			int64_t numVal = 0;
			if(val.size() > 0 && val.size() < sizeof(numBuf))
			{
				memcpy(numBuf, val.data(), val.size());
				numBuf[val.size()] = '\0';
				char *end = nullptr;
				numVal = strtoll(numBuf, &end, 10);
				isInt = (end == numBuf + val.size());
			}

			if(isInt)
			{
				CFObj<CFNumberRef> cfNum(CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &numVal));
				CFDictionarySetValue(dict, cfKey, cfNum);
			}
			else
			{
				CFObj<CFStringRef> cfVal = MakeCFStr(val);
				CFDictionarySetValue(dict, cfKey, cfVal);
			}
		}
	}
}


// The format of streamed/piped actions is one action per line, as follows:
// - ignore whitespace characters at the beginning of the line, if any
// - action and options come first in square brackets, e.g.: [clone], [move], [delete], [create file] [create directory]
// - the first character following the closing square bracket ']' is used as a field delimiter for the parameters to the action
// - variable length parameters are following, separated by the same field separator, specific to given actions

ActionStep
ActionDescriptionFromLine(const char *line, ssize_t linelen)
{
	// skip leading whitespace / control chars
	while(linelen > 0 && (unsigned char)*line <= 0x20) { line++; linelen--; }
	// strip trailing newline
	if(linelen > 0 && line[linelen-1] == '\n') linelen--;

	if(linelen <= 0 || *line != '[')
		return ActionStep{};
	line++; linelen--; // skip '['

	// scan to closing ']'
	const char *aoPtr = line;
	ssize_t aoLen = 0;
	while(linelen > 0 && *line != ']') { line++; linelen--; aoLen++; }
	if(linelen <= 0)
		return ActionStep{}; // no ']' found

	line++; linelen--; // skip ']'

	// first char after ']' is the field separator
	if(linelen <= 0)
		return ActionStep{};
	char sep = *line;
	line++; linelen--;

	if(linelen <= 0)
		return ActionStep{};

	std::string_view aoSV(aoPtr, (size_t)aoLen);
	std::string_view paramsSV(line, (size_t)linelen);

	// split action+options by space; first token is the action name
	auto aoTokens = SplitSV(aoSV, ' ');
	if(aoTokens.empty() || aoTokens[0].empty())
		return ActionStep{};
	std::string_view actionName = aoTokens[0];

	// split params by the field separator
	auto params = SplitSV(paramsSV, sep);
	size_t paramCount = params.size();

	CFObj<CFMutableDictionaryRef> dict(CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));

	CFObj<CFStringRef> cfAction = MakeCFStr(actionName);
	CFDictionarySetValue(dict, CFSTR("action"), cfAction);

	bool isSourceDestAction = false;
	Action action = ActionFromName(actionName, isSourceDestAction);

	if(action == kActionInvalid)
	{
		// defer the error to the parsing/dispatch code
		return ActionStep((CFDictionaryRef)dict);
	}

	if(isSourceDestAction)
	{
		if(paramCount > 0) { CFObj<CFStringRef> s = MakeCFStr(params[0]); CFDictionarySetValue(dict, CFSTR("from"), s); }
		if(paramCount > 1) { CFObj<CFStringRef> s = MakeCFStr(params[1]); CFDictionarySetValue(dict, CFSTR("to"),   s); }
	}
	else
	{
		switch(action)
		{
			case kFileActionDelete:
			case kFileActionRead:
			{ // all params are item paths
				CFDictionarySetValue(dict, CFSTR("items"), CFArrayFromSVs(params));
			}
			break;

			case kFileActionList:
			case kFileActionTree:
			{ // first param is directory path; depth modifier handled via AddOptionsToActionDescription
				if(paramCount > 0) { CFObj<CFStringRef> s = MakeCFStr(params[0]); CFDictionarySetValue(dict, CFSTR("directory"), s); }
			}
			break;

			case kFileActionInfo:
			{
				if(paramCount > 0) { CFObj<CFStringRef> s = MakeCFStr(params[0]); CFDictionarySetValue(dict, CFSTR("path"), s); }
			}
			break;

			case kFileActionEdit:
			{ // path  oldText  newText  — modifiers from options
				if(paramCount > 0)
				{
					CFObj<CFMutableArrayRef> items(CFArrayCreateMutable(kCFAllocatorDefault, 1, &kCFTypeArrayCallBacks));
					CFObj<CFStringRef> p0 = MakeCFStr(params[0]);
					CFArrayAppendValue(items, p0);
					CFDictionarySetValue(dict, CFSTR("items"), items);
				}
				if(paramCount > 1) { CFObj<CFStringRef> s = MakeCFStr(params[1]); CFDictionarySetValue(dict, CFSTR("oldText"), s); }
				if(paramCount > 2) { CFObj<CFStringRef> s = MakeCFStr(params[2]); CFDictionarySetValue(dict, CFSTR("newText"), s); }
			}
			break;

			case kFileActionGlob:
			{ // root  pattern1  pattern2  …  (prefix '!' = exclude)
				if(paramCount > 0) { CFObj<CFStringRef> s = MakeCFStr(params[0]); CFDictionarySetValue(dict, CFSTR("root"), s); }
				CFObj<CFMutableArrayRef> globs(CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks));
				CFObj<CFMutableArrayRef> excludes(CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks));
				for(size_t i = 1; i < paramCount; i++)
				{
					if(!params[i].empty() && params[i][0] == '!')
					{
						CFObj<CFStringRef> s = MakeCFStr(params[i].substr(1));
						CFArrayAppendValue(excludes, s);
					}
					else
					{
						CFObj<CFStringRef> s = MakeCFStr(params[i]);
						CFArrayAppendValue(globs, s);
					}
				}
				if(CFArrayGetCount(globs) > 0)   CFDictionarySetValue(dict, CFSTR("glob"),    globs);
				if(CFArrayGetCount(excludes) > 0) CFDictionarySetValue(dict, CFSTR("exclude"), excludes);
			}
			break;

			case kFileActionCreate:
			{
				bool isDir = std::any_of(aoTokens.begin(), aoTokens.end(),
					[](std::string_view sv){ return sv == "directory"; });
				if(isDir)
				{
					if(paramCount > 0) { CFObj<CFStringRef> s = MakeCFStr(params[0]); CFDictionarySetValue(dict, CFSTR("directory"), s); }
				}
				else
				{
					if(paramCount > 0) { CFObj<CFStringRef> s = MakeCFStr(params[0]); CFDictionarySetValue(dict, CFSTR("file"), s); }
					if(paramCount > 1) { CFObj<CFStringRef> s = MakeCFStr(params[1]); CFDictionarySetValue(dict, CFSTR("content"), s); }
				}
			}
			break;

			case kActionExecuteTool:
			{
				if(paramCount > 0) { CFObj<CFStringRef> s = MakeCFStr(params[0]); CFDictionarySetValue(dict, CFSTR("tool"), s); }
				if(paramCount > 1)
					CFDictionarySetValue(dict, CFSTR("arguments"), CFArrayFromSVs(params, 1));
			}
			break;

			case kActionEcho:
			{
				if(paramCount > 0) { CFObj<CFStringRef> s = MakeCFStr(params[0]); CFDictionarySetValue(dict, CFSTR("text"), s); }
			}
			break;

			default:
			break;
		}
	}

	AddOptionsToActionDescription(dict, aoTokens);

	// ActionStep ctor retains dict; local CFObj releases on return → net retain=1 in ActionStep.
	return ActionStep((CFDictionaryRef)dict);
}


void
StreamActionsFromStdIn(ReplayContext *context)
{
	StartReceivingActions(context);

	char *line = NULL;
	size_t linecap = 0;
	ssize_t linelen;
	while((linelen = getline(&line, &linecap, stdin)) > 0)
	{
		ActionStep step = ActionDescriptionFromLine(line, linelen);
		if(!step.empty())
		{
			if(context->concurrent)
				DispatchTaskConcurrentlyWithNoDependency(std::move(step), context);
			else
				DispatchTaskSerially(std::move(step), context);
		}
		else
		{
			if(context->stopOnError)
			{
				LogError("error: malformed action description on stdin: %s\n", line);
				context->lastError.set("error: malformed action description on stdin", 1);
				break;
			}
			else
			{
				LogError("warning: ignoring malformed action description on stdin: %s\n", line);
			}
		}
	}

	FinishReceivingActionsAndWait(context);

	//do not bother freeing the line buffer - the process is ending
}
