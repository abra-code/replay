#import "StringAndPath.h"

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
					fprintf(gLogErr, "error: referenced environment variable \"%s\" not found\n", [envVarName UTF8String]);
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
				fprintf(gLogErr, "error: unterminated environment variable sequence at character %lu in string \"%s\"\n", chunkStart-1, [origString UTF8String]);
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

NSString *
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


NSArray<NSURL*> *
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

NSArray<NSURL*> *
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

