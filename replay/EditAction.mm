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

// ---------------------------------------------------------------------------
// Unified diff for dryRun output
// ---------------------------------------------------------------------------

static std::vector<std::string> split_lines_for_diff(const std::string &s)
{
    std::vector<std::string> v;
    size_t p = 0;
    while (p <= s.size())
    {
        size_t nl = s.find('\n', p);
        if (nl == std::string::npos)
        {
            if (p < s.size()) v.push_back(s.substr(p));
            break;
        }
        v.push_back(s.substr(p, nl - p));
        p = nl + 1;
    }
    return v;
}

// Single-hunk unified diff using common-prefix/suffix approach.
// Correct for localized replacements; multi-edit spans collapse into one hunk.
static std::string make_unified_diff(const char *path,
                                      const std::string &orig,
                                      const std::string &modified)
{
    if (orig == modified)
        return "(no changes)\n";

    const auto A = split_lines_for_diff(orig);
    const auto B = split_lines_for_diff(modified);
    const int m = (int)A.size(), n = (int)B.size();
    const int kCtx = 3;

    int prefix = 0;
    while (prefix < m && prefix < n && A[prefix] == B[prefix])
        ++prefix;

    int suffix = 0;
    while (suffix < m - prefix && suffix < n - prefix &&
           A[m - 1 - suffix] == B[n - 1 - suffix])
        ++suffix;

    int a_lo = prefix, a_hi = m - suffix;   // deleted: A[a_lo..a_hi)
    int b_lo = prefix, b_hi = n - suffix;   // inserted: B[b_lo..b_hi)

    int ctx_before = std::min(kCtx, a_lo);
    int ctx_after  = std::min(kCtx, m - a_hi);

    int ha_start = a_lo - ctx_before + 1;  // 1-based
    int ha_count = ctx_before + (a_hi - a_lo) + ctx_after;
    int hb_start = b_lo - ctx_before + 1;
    int hb_count = ctx_before + (b_hi - b_lo) + ctx_after;

    std::string out;
    out += "--- "; out += path; out += "\n";
    out += "+++ "; out += path; out += "\n";
    out += "@@ -"; out += std::to_string(ha_start);
    out += ",";    out += std::to_string(ha_count);
    out += " +";   out += std::to_string(hb_start);
    out += ",";    out += std::to_string(hb_count);
    out += " @@\n";

    for (int i = a_lo - ctx_before; i < a_lo; ++i)
        { out += ' '; out += A[i]; out += '\n'; }
    for (int i = a_lo; i < a_hi; ++i)
        { out += '-'; out += A[i]; out += '\n'; }
    for (int i = b_lo; i < b_hi; ++i)
        { out += '+'; out += B[i]; out += '\n'; }
    for (int i = a_hi; i < a_hi + ctx_after; ++i)
        { out += ' '; out += A[i]; out += '\n'; }

    return out;
}

// ---------------------------------------------------------------------------
// Whitespace-normalized matching — standard MCP fallback when exact fails
// ---------------------------------------------------------------------------

// Check whether content_lines[start .. start+count) matches old_norm_lines
// when each side has its common leading whitespace stripped.
static bool normalized_region_matches(
    const std::vector<std::string> &content_lines, int start,
    const std::vector<std::string> &old_norm_lines)
{
    int count = (int)old_norm_lines.size();
    if (start < 0 || start + count > (int)content_lines.size())
        return false;

    // Minimum indent of the content region (ignoring empty lines)
    size_t c_min = SIZE_MAX;
    for (int i = 0; i < count; ++i)
    {
        const auto &line = content_lines[start + i];
        if (line.empty()) continue;
        size_t ws = 0;
        while (ws < line.size() && (line[ws] == ' ' || line[ws] == '\t'))
            ++ws;
        c_min = std::min(c_min, ws);
    }
    if (c_min == SIZE_MAX) c_min = 0;

    for (int i = 0; i < count; ++i)
    {
        const auto &cl = content_lines[start + i];
        const auto &ol = old_norm_lines[i];
        size_t skip = std::min(c_min, cl.size());
        std::string_view c_stripped(cl.data() + skip, cl.size() - skip);
        if (c_stripped != ol)
            return false;
    }
    return true;
}

// Apply a single literal replacement using whitespace-normalized line matching.
// Finds the first block of lines in `content` that matches `old_str` lines
// when both sides are stripped of their common leading indentation.
// On success modifies `content` in place and returns true.
// On failure sets *outError and returns false without modifying `content`.
static bool apply_whitespace_normalized(std::string &content,
                                         const std::string &old_str,
                                         const std::string &new_str,
                                         NSString * __nullable * __nonnull outError)
{
    // Split old_str into lines (no trailing-newline element)
    std::vector<std::string> old_lines;
    {
        size_t p = 0;
        while (true)
        {
            size_t nl = old_str.find('\n', p);
            if (nl == std::string::npos) { if (p < old_str.size()) old_lines.push_back(old_str.substr(p)); break; }
            old_lines.push_back(old_str.substr(p, nl - p));
            p = nl + 1;
        }
    }
    if (old_lines.empty())
    {
        *outError = @"oldText is empty";
        return false;
    }

    // Minimum indent of old_str
    size_t old_min = SIZE_MAX;
    for (const auto &line : old_lines)
    {
        if (line.empty()) continue;
        size_t ws = 0;
        while (ws < line.size() && (line[ws] == ' ' || line[ws] == '\t')) ++ws;
        old_min = std::min(old_min, ws);
    }
    if (old_min == SIZE_MAX) old_min = 0;

    // Normalize old lines (strip common indent)
    std::vector<std::string> old_norm;
    for (const auto &line : old_lines)
        old_norm.push_back(line.size() > old_min ? line.substr(old_min) : "");

    // Split content into lines with byte offsets
    std::vector<std::string> content_lines;
    std::vector<size_t> line_starts;
    {
        size_t p = 0;
        while (p <= content.size())
        {
            size_t nl = content.find('\n', p);
            if (nl == std::string::npos)
            {
                if (p < content.size()) { line_starts.push_back(p); content_lines.push_back(content.substr(p)); }
                break;
            }
            line_starts.push_back(p);
            content_lines.push_back(content.substr(p, nl - p));
            p = nl + 1;
        }
    }

    int m = (int)old_norm.size();
    int n = (int)content_lines.size();

    int match_at = -1;
    for (int i = 0; i + m <= n; ++i)
    {
        if (normalized_region_matches(content_lines, i, old_norm))
        {
            match_at = i;
            break;
        }
    }

    if (match_at < 0)
    {
        *outError = [NSString stringWithFormat:@"oldText not found: %s", old_str.c_str()];
        return false;
    }

    // Determine actual indentation of matched region (min indent of non-empty lines)
    size_t c_min = SIZE_MAX;
    for (int i = 0; i < m; ++i)
    {
        const auto &cl = content_lines[match_at + i];
        if (cl.empty()) continue;
        size_t ws = 0;
        while (ws < cl.size() && (cl[ws] == ' ' || cl[ws] == '\t')) ++ws;
        c_min = std::min(c_min, ws);
    }
    if (c_min == SIZE_MAX) c_min = 0;

    // Indent string from first non-empty matched line
    std::string actual_indent;
    for (int i = 0; i < m; ++i)
    {
        const auto &cl = content_lines[match_at + i];
        if (!cl.empty()) { actual_indent = cl.substr(0, c_min); break; }
    }

    // Byte range of matched region (including trailing newlines except possibly last)
    size_t region_start = line_starts[match_at];
    size_t region_end = (match_at + m < n) ? line_starts[match_at + m] : content.size();

    // Build replacement with adjusted indentation
    std::string replacement;
    {
        std::vector<std::string> new_lines;
        {
            size_t p = 0;
            while (true)
            {
                size_t nl = new_str.find('\n', p);
                if (nl == std::string::npos) { new_lines.push_back(new_str.substr(p)); break; }
                new_lines.push_back(new_str.substr(p, nl - p));
                p = nl + 1;
            }
        }
        // Minimum indent of new_str
        size_t new_min = SIZE_MAX;
        for (const auto &line : new_lines)
        {
            if (line.empty()) continue;
            size_t ws = 0;
            while (ws < line.size() && (line[ws] == ' ' || line[ws] == '\t')) ++ws;
            new_min = std::min(new_min, ws);
        }
        if (new_min == SIZE_MAX) new_min = 0;

        bool last_has_nl = !new_str.empty() && new_str.back() == '\n';
        for (size_t i = 0; i < new_lines.size(); ++i)
        {
            const auto &line = new_lines[i];
            if (!line.empty())
            {
                std::string stripped = line.size() > new_min ? line.substr(new_min) : "";
                replacement += actual_indent + stripped;
            }
            bool is_last = (i + 1 == new_lines.size());
            if (!is_last || last_has_nl)
                replacement += '\n';
        }
    }

    content.replace(region_start, region_end - region_start, replacement);
    return true;
}

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
			// Standard MCP fallback: whitespace-normalized line matching
			if (limit == 1 && !case_insensitive)
			{
				NSString *normError = nil;
				if (apply_whitespace_normalized(content, old_text, new_text, &normError))
					return true;
			}
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
		// Read file, apply edits to a copy, and return a unified diff.
		std::ifstream df(filePath, std::ios::binary | std::ios::ate);
		if (df.is_open())
		{
			std::streamoff dfSize = df.tellg();
			df.seekg(0, std::ios::beg);
			std::string orig((size_t)dfSize, '\0');
			if (dfSize > 0 && !df.read(&orig[0], dfSize))
				return {false, -32002, std::string("dryRun: failed to read \"") + filePath + "\""};
			df.close();

			std::string modified = orig;
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
				if (!apply_one_edit(modified, old_str, new_str, limit, use_regex, case_insensitive, &editError))
					return {false, -32603, [editError UTF8String]};
			}
			return {true, 0, make_unified_diff(filePath, orig, modified)};
		}
		// File does not exist yet — fall back to listing the intended edits.
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

MCPGrepResult
GrepFileMCPCore(const char *filePath, const std::string &pattern,
                  bool use_regex, bool case_insensitive,
                  int context_lines, int max_matches)
{
    MCPGrepResult result;

    std::ifstream f(filePath, std::ios::binary | std::ios::ate);
    if (!f.is_open())
    {
        result.error = std::string("cannot open: ") + strerror(errno);
        return result;
    }
    std::streamoff file_size = f.tellg();
    f.seekg(0, std::ios::beg);
    std::string content((size_t)file_size, '\0');
    if (file_size > 0 && !f.read(&content[0], file_size))
    {
        result.error = "read failed";
        return result;
    }
    f.close();

    // Binary check: null bytes in first 4 KB → skip
    {
        size_t check = std::min((size_t)4096, content.size());
        if (memchr(content.data(), '\0', check) != nullptr)
        {
            result.is_binary = true;
            return result;
        }
    }

    // Split into lines, recording [start, end) per line (end excludes the newline)
    std::vector<std::pair<size_t, size_t>> line_ranges;
    {
        size_t pos = 0;
        while (pos <= content.size())
        {
            size_t nl = content.find('\n', pos);
            if (nl == std::string::npos)
            {
                if (pos < content.size())
                    line_ranges.push_back({pos, content.size()});
                break;
            }
            size_t end = nl;
            if (end > pos && content[end - 1] == '\r')
                --end;
            line_ranges.push_back({pos, end});
            pos = nl + 1;
        }
    }

    // Compile regex (REG_NOSUB: we only need match/no-match, not sub-expressions)
    regex_t re;
    bool re_compiled = false;
    if (use_regex)
    {
        int flags = REG_EXTENDED | REG_NOSUB;
        if (case_insensitive) flags |= REG_ICASE;
        int err = regcomp(&re, pattern.c_str(), flags);
        if (err != 0)
        {
            char buf[512];
            regerror(err, &re, buf, sizeof(buf));
            regfree(&re);
            result.error = std::string("regex error: ") + buf;
            return result;
        }
        re_compiled = true;
    }

    // Find matching line indices (stop counting at max_matches)
    const int n_lines = (int)line_ranges.size();
    std::vector<int> match_indices;
    for (int i = 0; i < n_lines && result.match_count < max_matches; ++i)
    {
        auto [s, e] = line_ranges[i];
        // Build null-terminated line string; the regexec/find operates on it
        std::string line(content.data() + s, e - s);
        bool matched = false;
        if (use_regex)
        {
            matched = (regexec(&re, line.c_str(), 0, nullptr, 0) == 0);
        }
        else if (case_insensitive)
        {
            matched = (strcasestr(line.c_str(), pattern.c_str()) != nullptr);
        }
        else
        {
            matched = (line.find(pattern) != std::string::npos);
        }
        if (matched)
        {
            match_indices.push_back(i);
            ++result.match_count;
        }
    }

    if (re_compiled)
        regfree(&re);

    if (match_indices.empty())
        return result; // text stays empty

    // Format grep-style output with context lines
    std::string &out = result.text;
    int last_printed = -1;

    auto append_line = [&](int i, bool is_match)
    {
        auto [s, e] = line_ranges[i];
        out += filePath;
        char delim = is_match ? ':' : '-';
        out += delim;
        out += std::to_string(i + 1); // 1-based
        out += delim;
        out.append(content.data() + s, e - s);
        out += '\n';
        last_printed = i;
    };

    for (int mi = 0; mi < (int)match_indices.size(); ++mi)
    {
        int m          = match_indices[mi];
        int ctx_start  = std::max(0, m - context_lines);
        int ctx_end    = std::min(n_lines - 1, m + context_lines);

        // Group separator when there is a gap since last printed line
        if (last_printed >= 0 && ctx_start > last_printed + 1)
            out += "--\n";

        // Context before (continue from where we left off to avoid reprinting)
        for (int j = std::max(ctx_start, last_printed + 1); j < m; ++j)
            append_line(j, false);

        // Match line (may already be printed when it overlaps previous context)
        if (m > last_printed)
            append_line(m, true);

        // Context after (stop where the next match's leading context begins)
        int next_ctx_start = (mi + 1 < (int)match_indices.size())
                           ? std::max(m + 1, match_indices[mi + 1] - context_lines)
                           : n_lines;
        for (int j = m + 1; j <= ctx_end && j < next_ctx_start; ++j)
            append_line(j, false);
    }

    return result;
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
