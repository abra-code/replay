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
ReadFile(const std::string &filePath, ReplayContext *context, ActionContext *actionContext)
{
	if (!context->mcpServer && context->stopOnError && context->lastError.hasError())
		return false;

	if (context->mcpServer)
	{
		std::ifstream f(filePath, std::ios::binary | std::ios::ate);
		if (!f.is_open())
		{
			int err = errno;
			std::string errStr = std::string("failed to open \"") + filePath + "\" for reading: " + strerror(err);
			PrintMCPError(context, actionContext, -32002, std::move(errStr));
			return false;
		}
		std::streamoff fileSize = f.tellg();
		f.seekg(0, std::ios::beg);
		std::vector<uint8_t> data(static_cast<size_t>(fileSize));
		if (fileSize > 0 && !f.read(reinterpret_cast<char *>(data.data()), fileSize))
		{
			std::string errStr = std::string("failed to read \"") + filePath + "\"";
			PrintMCPError(context, actionContext, -32002, std::move(errStr));
			return false;
		}
		if (is_utf8_text(data.data(), data.size()))
		{
			std::string text(reinterpret_cast<const char *>(data.data()), data.size());
			PrintMCPTextResult(context, actionContext, std::move(text));
		}
		else
		{
			unsigned long encodedSize = CalculateEncodedBufferSize((unsigned long)data.size());
			std::vector<unsigned char> encoded(encodedSize + 1, 0);
			unsigned long written = EncodeBase64(data.data(), (unsigned long)data.size(),
			                                     encoded.data(), encodedSize);
			std::string b64(reinterpret_cast<const char *>(encoded.data()), written);
			PrintMCPBlobResult(context, actionContext, std::move(b64), "application/octet-stream");
		}
		return true;
	}

	if (context->verbose || context->dryRun)
	{
		std::string desc = std::string("[read]\t") + filePath + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
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
		std::string errStr = std::string("error: failed to open \"") + filePath + "\" for reading: " + strerror(err) + "\n";
		context->lastError.set(errStr, err);
		PrintToStdErr(context, std::move(errStr));
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	std::streamoff fileSize = f.tellg();
	f.seekg(0, std::ios::beg);

	std::vector<uint8_t> data(static_cast<size_t>(fileSize));
	if (fileSize > 0 && !f.read(reinterpret_cast<char *>(data.data()), fileSize))
	{
		std::string errStr = std::string("error: failed to read \"") + filePath + "\"\n";
		context->lastError.set(errStr, EIO);
		PrintToStdErr(context, std::move(errStr));
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	if (is_utf8_text(data.data(), data.size()))
	{
		// Build output directly from the raw bytes — no NSString round-trip
		// (avoids UTF-8→UTF-16→UTF-8 conversion+copy for potentially large content)
		std::string output;
		output.reserve(6 + filePath.size() + 2 + data.size() + 1);
		output += "[text:";
		output += filePath;
		output += "]\n";
		output.append(reinterpret_cast<const char *>(data.data()), data.size());
		if (output.empty() || output.back() != '\n')
			output += '\n';
		PrintToStdOut(context, std::move(output), actionContext->index);
	}
	else
	{
		unsigned long encodedSize = CalculateEncodedBufferSize((unsigned long)data.size());
		std::vector<unsigned char> encoded(encodedSize + 1, 0);
		unsigned long written = EncodeBase64(data.data(), (unsigned long)data.size(), encoded.data(), encodedSize);

		std::string output;
		output.reserve(6 + filePath.size() + 2 + written + 1);
		output += "[blob:";
		output += filePath;
		output += "]\n";
		output.append(reinterpret_cast<const char *>(encoded.data()), written);
		output += '\n';
		PrintToStdOut(context, std::move(output), actionContext->index);
	}

	return true;
}
