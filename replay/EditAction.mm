#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#include <regex.h>
#include <unistd.h>
#include <cerrno>
#include <fstream>
#include <string>
#include <vector>

// ============================================================================
// EditFile — search-replace with literal or POSIX ERE regex (inspired by filt)
// ============================================================================

struct ReplaceChunk {
	std::string literal;
	int sub_index; // -1 = literal text, 0-9 = regex back-reference
};

static std::vector<ReplaceChunk> parse_replacement(const std::string &repl)
{
	std::vector<ReplaceChunk> chunks;
	std::string cur;
	for (size_t i = 0; i < repl.size(); )
	{
		if (repl[i] == '\\' && i + 1 < repl.size())
		{
			char next = repl[i + 1];
			if (next >= '0' && next <= '9')
			{
				if (!cur.empty()) { chunks.push_back({std::move(cur), -1}); cur.clear(); }
				chunks.push_back({"", next - '0'});
				i += 2;
			}
			else
			{
				char escaped;
				bool recognized = true;
				switch (next)
				{
					case 'n': escaped = '\n'; break;
					case 't': escaped = '\t'; break;
					case 'r': escaped = '\r'; break;
					case '\\': escaped = '\\'; break;
					default: recognized = false; escaped = next; break;
				}
				if (!recognized) cur += '\\';
				cur += escaped;
				i += 2;
			}
		}
		else
		{
			cur += repl[i++];
		}
	}
	if (!cur.empty()) chunks.push_back({std::move(cur), -1});
	return chunks;
}

static std::string apply_chunks(const char *base, const std::vector<ReplaceChunk> &chunks,
                                const regmatch_t *matches, size_t nmatch)
{
	std::string result;
	for (const auto &chunk : chunks)
	{
		if (chunk.sub_index < 0)
		{
			result += chunk.literal;
		}
		else if ((size_t)chunk.sub_index < nmatch && matches[chunk.sub_index].rm_so >= 0)
		{
			result.append(base + matches[chunk.sub_index].rm_so,
			              (size_t)(matches[chunk.sub_index].rm_eo - matches[chunk.sub_index].rm_so));
		}
	}
	return result;
}

static size_t find_nocase(const std::string &text, const std::string &pattern, size_t start)
{
	if (pattern.empty()) return start;
	for (size_t i = start; i + pattern.size() <= text.size(); i++)
	{
		if (strncasecmp(text.c_str() + i, pattern.c_str(), pattern.size()) == 0)
			return i;
	}
	return std::string::npos;
}

// Apply one search-replace to content (in-place). Returns true on success.
// On failure, sets *outError and returns false.
static bool apply_one_edit(std::string &content,
                           const std::string &old_text, const std::string &new_text,
                           NSInteger limit, bool use_regex, bool case_insensitive,
                           NSString * __nullable * __nonnull outError)
{
	if (use_regex)
	{
		regex_t re;
		int flags = REG_EXTENDED;
		if (case_insensitive) flags |= REG_ICASE;
		int comp_err = regcomp(&re, old_text.c_str(), flags);
		if (comp_err != 0)
		{
			char buf[512];
			regerror(comp_err, &re, buf, sizeof(buf));
			*outError = [NSString stringWithFormat:@"regex compile error: %s", buf];
			regfree(&re);
			return false;
		}

		size_t nmatch = re.re_nsub + 1;
		std::vector<regmatch_t> matches(nmatch);
		auto chunks = parse_replacement(new_text);

		std::string result;
		size_t pos = 0;
		NSInteger count = 0;

		while (pos <= content.size())
		{
			if (limit > 0 && count >= limit) break;

			matches[0].rm_so = (regoff_t)pos;
			matches[0].rm_eo = (regoff_t)content.size();
			int merr = regexec(&re, content.c_str(), nmatch, matches.data(), REG_STARTEND);
			if (merr == REG_NOMATCH) break;
			if (merr != 0)
			{
				char buf[512];
				regerror(merr, &re, buf, sizeof(buf));
				*outError = [NSString stringWithFormat:@"regex match error: %s", buf];
				regfree(&re);
				return false;
			}

			regoff_t m_start = matches[0].rm_so;
			regoff_t m_end   = matches[0].rm_eo;

			result.append(content.data() + pos, (size_t)(m_start - pos));
			result += apply_chunks(content.c_str(), chunks, matches.data(), nmatch);
			count++;

			if (m_end > m_start)
			{
				pos = (size_t)m_end;
			}
			else
			{
				// Zero-length match: copy one char verbatim and advance to avoid infinite loop
				if (pos < content.size())
					result += content[pos];
				pos++;
			}
		}

		result.append(content.data() + pos, content.size() - pos);
		regfree(&re);

		if (limit > 0 && count == 0)
		{
			*outError = [NSString stringWithFormat:@"pattern not found: %s", old_text.c_str()];
			return false;
		}

		content = std::move(result);
		return true;
	}
	else
	{
		// Literal mode
		if (old_text.empty())
		{
			*outError = @"oldText must not be empty";
			return false;
		}

		std::string result;
		size_t pos = 0;
		NSInteger count = 0;

		while (pos < content.size())
		{
			if (limit > 0 && count >= limit) break;

			size_t found = case_insensitive
				? find_nocase(content, old_text, pos)
				: content.find(old_text, pos);

			if (found == std::string::npos) break;

			result.append(content.data() + pos, found - pos);
			result += new_text;
			pos = found + old_text.size();
			count++;
		}

		result.append(content.data() + pos, content.size() - pos);

		if (limit > 0 && count == 0)
		{
			*outError = [NSString stringWithFormat:@"oldText not found: %s", old_text.c_str()];
			return false;
		}

		content = std::move(result);
		return true;
	}
}

MCPEditResult
EditFileMCPCore(const char *filePath, NSArray<NSDictionary *> *edits, bool dryRun)
{
	if (dryRun)
	{
		std::string plan = std::string("Dry-run edit plan for ") + filePath + ":\n";
		for (NSDictionary *edit in edits)
		{
			NSString *old = edit[@"oldText"] ?: @"";
			NSString *neu = edit[@"newText"] ?: @"";
			id limitVal = edit[@"limit"];
			NSInteger lim = [limitVal isKindOfClass:[NSNumber class]] ? [limitVal integerValue] : 1;
			id regexVal = edit[@"regex"];
			bool useRegex = [regexVal isKindOfClass:[NSNumber class]] ? [regexVal boolValue] : false;
			plan += "  oldText: "; plan += [old UTF8String]; plan += "\n";
			plan += "  newText: "; plan += [neu UTF8String]; plan += "\n";
			plan += "  limit: "; plan += std::to_string((long)lim); plan += "\n";
			if (useRegex) plan += "  regex: true\n";
			plan += "\n";
		}
		return {true, 0, std::move(plan)};
	}

	std::ifstream f(filePath, std::ios::binary | std::ios::ate);
	if (!f.is_open())
	{
		int err = errno;
		return {false, -32002, std::string("failed to open \"") + filePath + "\": " + strerror(err)};
	}
	std::streamoff fileSize = f.tellg();
	f.seekg(0, std::ios::beg);
	std::string content((size_t)fileSize, '\0');
	if (fileSize > 0 && !f.read(&content[0], fileSize))
		return {false, -32002, std::string("failed to read \"") + filePath + "\""};
	f.close();

	for (NSDictionary *edit in edits)
	{
		NSString *oldText = edit[@"oldText"];
		NSString *newText = edit[@"newText"];
		if (![oldText isKindOfClass:[NSString class]])
			return {false, -32602, "edit: \"oldText\" must be a string"};
		if (![newText isKindOfClass:[NSString class]]) newText = @"";

		std::string old_str([oldText UTF8String]);
		std::string new_str([newText UTF8String]);
		id limitVal = edit[@"limit"];
		NSInteger limit = [limitVal isKindOfClass:[NSNumber class]] ? [limitVal integerValue] : 1;
		id regexVal = edit[@"regex"];
		bool use_regex = [regexVal isKindOfClass:[NSNumber class]] ? [regexVal boolValue] : false;
		id caseVal = edit[@"case-insensitive"];
		bool case_insensitive = [caseVal isKindOfClass:[NSNumber class]] ? [caseVal boolValue] : false;

		NSString *editError = nil;
		if (!apply_one_edit(content, old_str, new_str, limit, use_regex, case_insensitive, &editError))
			return {false, -32603, [editError UTF8String]};
	}

	std::string pathStr(filePath);
	size_t lastSlash = pathStr.rfind('/');
	std::string dir = (lastSlash != std::string::npos) ? pathStr.substr(0, lastSlash) : ".";
	std::string tmpl = dir + "/.replay_edit_XXXXXX";
	int tmpFd = mkstemp(&tmpl[0]);
	if (tmpFd < 0)
	{
		int err = errno;
		return {false, -32603, std::string("failed to create temp file: ") + strerror(err)};
	}
	bool write_ok = content.empty() ||
	                ::write(tmpFd, content.data(), content.size()) == (ssize_t)content.size();
	::close(tmpFd);
	if (!write_ok || ::rename(tmpl.c_str(), filePath) != 0)
	{
		int err = errno;
		::unlink(tmpl.c_str());
		return {false, -32603, std::string("failed to write \"") + filePath + "\": " + strerror(err)};
	}

	return {true, 0, std::string("Successfully edited ") + filePath};
}

bool
EditFile(const char *filePath, NSArray<NSDictionary *> *edits, bool actionDryRun,
         ReplayContext *context, ActionContext *actionContext)
{
	if (!context->mcpServer && context->stopOnError && context->lastError.hasError())
		return false;

	if (context->mcpServer)
	{
		auto r = EditFileMCPCore(filePath, edits, actionDryRun);
		if (r.ok)
			PrintMCPTextResult(context, actionContext, r.message);
		else
			PrintMCPError(context, actionContext, r.error_code, r.message);
		return r.ok;
	}

	bool combined_dry_run = context->dryRun || actionDryRun;

	// Slot 1: verbose/dry-run descriptor
	if (context->verbose || combined_dry_run)
	{
		std::string desc = std::string("[edit]\t") + filePath + "\n";
		PrintToStdOut(context, std::move(desc), actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}
	actionContext->index++;

	// Slot 2: action-dry-run plan or nothing
	if (combined_dry_run)
	{
		if (actionDryRun && !context->dryRun)
		{
			std::string plan = std::string("[edit-dry-run:") + filePath + "]\n";
			for (NSDictionary *edit in edits)
			{
				NSString *old = edit[@"oldText"] ?: @"";
				NSString *neu = edit[@"newText"] ?: @"";
				id limitVal = edit[@"limit"];
				NSInteger lim = [limitVal isKindOfClass:[NSNumber class]] ? [limitVal integerValue] : 1;
				id regexVal = edit[@"regex"];
				bool useRegex = [regexVal isKindOfClass:[NSNumber class]] ? [regexVal boolValue] : false;
				plan += "  \"";
				plan += [old UTF8String];
				plan += "\" \xe2\x86\x92 \"";
				plan += [neu UTF8String];
				plan += "\" (limit=";
				plan += std::to_string((long)lim);
				plan += useRegex ? " regex)\n" : ")\n";
			}
			PrintToStdOut(context, std::move(plan), actionContext->index);
		}
		else
		{
			ActionWithNoOutput(context, actionContext->index);
		}
		return true;
	}

	// Read file content
	std::ifstream f(filePath, std::ios::binary | std::ios::ate);
	if (!f.is_open())
	{
		int err = errno;
		std::string errStr = std::string("error: edit: failed to open \"") + filePath + "\": " + strerror(err) + "\n";
		context->lastError.set(errStr, err);
		PrintToStdErr(context, std::move(errStr));
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	std::streamoff fileSize = f.tellg();
	f.seekg(0, std::ios::beg);
	std::string content((size_t)fileSize, '\0');
	if (fileSize > 0 && !f.read(&content[0], fileSize))
	{
		std::string errStr = std::string("error: edit: failed to read \"") + filePath + "\"\n";
		context->lastError.set(errStr, EIO);
		PrintToStdErr(context, std::move(errStr));
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}
	f.close();

	// Apply each edit in sequence
	for (NSDictionary *edit in edits)
	{
		NSString *oldText = edit[@"oldText"];
		NSString *newText = edit[@"newText"];

		if (![oldText isKindOfClass:[NSString class]])
		{
			std::string errStr = std::string("error: edit \"") + filePath + "\": \"oldText\" must be a string\n";
			context->lastError.set(errStr, EINVAL);
			PrintToStdErr(context, std::move(errStr));
			ActionWithNoOutput(context, actionContext->index);
			return false;
		}
		if (![newText isKindOfClass:[NSString class]])
			newText = @"";

		std::string old_str([oldText UTF8String]);
		std::string new_str([newText UTF8String]);

		id limitVal = edit[@"limit"];
		NSInteger limit = [limitVal isKindOfClass:[NSNumber class]] ? [limitVal integerValue] : 1;

		id regexVal = edit[@"regex"];
		bool use_regex = [regexVal isKindOfClass:[NSNumber class]] ? [regexVal boolValue] : false;

		id caseVal = edit[@"case-insensitive"];
		bool case_insensitive = [caseVal isKindOfClass:[NSNumber class]] ? [caseVal boolValue] : false;

		NSString *editError = nil;
		if (!apply_one_edit(content, old_str, new_str, limit, use_regex, case_insensitive, &editError))
		{
			std::string errStr = std::string("error: edit \"") + filePath + "\": " + [editError UTF8String] + "\n";
			context->lastError.set(errStr, 1);
			PrintToStdErr(context, std::move(errStr));
			ActionWithNoOutput(context, actionContext->index);
			return false;
		}
	}

	// Write atomically: temp file in same directory, then rename
	std::string pathStr(filePath);
	size_t lastSlash = pathStr.rfind('/');
	std::string dir = (lastSlash != std::string::npos) ? pathStr.substr(0, lastSlash) : ".";
	std::string tmpl = dir + "/.replay_edit_XXXXXX";

	int tmpFd = mkstemp(&tmpl[0]);
	if (tmpFd < 0)
	{
		int err = errno;
		std::string errStr = std::string("error: edit: failed to create temp file: ") + strerror(err) + "\n";
		context->lastError.set(errStr, err);
		PrintToStdErr(context, std::move(errStr));
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	bool write_ok = content.empty() ||
	                ::write(tmpFd, content.data(), content.size()) == (ssize_t)content.size();
	::close(tmpFd);

	if (!write_ok || ::rename(tmpl.c_str(), filePath) != 0)
	{
		int err = errno;
		::unlink(tmpl.c_str());
		std::string errStr = std::string("error: edit: failed to write \"") + filePath + "\": " + strerror(err) + "\n";
		context->lastError.set(errStr, err);
		PrintToStdErr(context, std::move(errStr));
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	ActionWithNoOutput(context, actionContext->index);
	return true;
}
