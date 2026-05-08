#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#include "ABase64.h"
#include <cerrno>
#include <fstream>
#include <vector>
#include <string>

static bool is_utf8_text(const uint8_t *data, size_t len)
{
	size_t i = 0;
	while (i < len)
	{
		uint8_t c = data[i];
		if (c == 0) return false;
		size_t seqLen;
		if      ((c & 0x80) == 0x00) seqLen = 1;
		else if ((c & 0xE0) == 0xC0) seqLen = 2;
		else if ((c & 0xF0) == 0xE0) seqLen = 3;
		else if ((c & 0xF8) == 0xF0) seqLen = 4;
		else return false;
		for (size_t j = 1; j < seqLen; j++)
		{
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
