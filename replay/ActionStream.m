//
//  ActionStream.m
//
//  Created by Tomasz Kukielka on 12/26/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import "ReplayServer.h"
#import "ConcurrentDispatchWithNoDependency.h"
#import "SerialDispatch.h"

void
StartReceivingActions(ReplayContext *context)
{
	if(context->concurrent)
	{
		context->outputSerializer = [OutputSerializer sharedOutputSerializer];
		context->actionCounter = -1;
		context->analyzeDependencies = false; // building dependency graph is not supported when tasks are streamed
		StartConcurrentDispatchWithNoDependency(context);
	}
	else
	{
 		// output is ordered by the virtue of serial execution
 		// but we don't want to trigger the complex infra for ordering of concurrent task outputs
 		context->outputSerializer = nil;
		context->actionCounter = -1;
		context->orderedOutput = false;
		StartSerialDispatch(context);
	}
}

void
FinishReceivingActionsAndWait(ReplayContext *context)
{
	if(context->concurrent)
	{
		FinishConcurrentDispatchWithNoDependencyAndWait(context);
		FlushSerializedOutputs(context->outputSerializer);
	}
	else
	{
		FinishSerialDispatchAndWait(context);
	}
}

void
StreamActionsFromStdIn(ReplayContext *context)
{
	StartReceivingActions(context);

	char *line = NULL;
	size_t linecap = 0;
	ssize_t linelen;
	while ((linelen = getline(&line, &linecap, stdin)) > 0)
	{
		NSDictionary *actionDescription = ActionDescriptionFromLine(line, linelen);
		if(actionDescription != nil)
		{
			if(context->concurrent)
				DispatchTaskConcurrentlyWithNoDependency(actionDescription, context);
			else
				DispatchTaskSerially(actionDescription, context);
		}
		else
		{
			if(context->stopOnError)
			{
				fprintf(gLogErr, "error: malformed action description on stdin: %s\n", line);
				NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: @"Malformed action description on stdin" };
				context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:1 userInfo:userInfo];
				break;
			}
			else
			{
				fprintf(gLogErr, "warning: ignoring malformed action description on stdin: %s\n", line);
			}
		}
	}

	FinishReceivingActionsAndWait(context);

	//do not bother freeing the line buffer - the process is ending
}


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
				fprintf(gLogErr, "warning: invalid option: %s\n", [oneOption UTF8String]);
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
// The following example uses a different separator: "+" to explicitly show delimited parameters:
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
