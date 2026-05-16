#import <Foundation/Foundation.h>
#include "FileTree.h"
#include "LogStream.h"

#ifdef __cplusplus
#include <atomic>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

// Thread-safe error holder. hasError() is a lock-free atomic read — hot path in
// every action guard. set/clear/description take a mutex for the string payload.

// Note: The explicit std::atomic load/store are used here specifically to override the default memory order.
// The implicit operators use memory_order_seq_cst — the strongest and most expensive ordering, which emits a full memory barrier on ARM.
// The explicit calls use memory_order_acquire/release, which on Apple Silicon compile to ldar/stlr (load-acquire/store-release) instead of ldar + dmb ish.
// The explicit load/store calls are worth keeping here since hasError() is the guard check at the top of every action — it's called constantly during execution.

struct ReplayError {
	bool hasError() const noexcept {
		return _flag.load(std::memory_order_acquire);
	}
	void set(std::string description, int code = 1) {
		std::lock_guard<std::mutex> lk(_mutex);
		_description = std::move(description);
		_code = code;
		_flag.store(true, std::memory_order_release);
	}
	void clear() {
		std::lock_guard<std::mutex> lk(_mutex);
		_description.clear();
		_code = 0;
		_flag.store(false, std::memory_order_release);
	}
	std::string description() const {
		std::lock_guard<std::mutex> lk(_mutex);
		return _description;
	}
	int code() const {
		std::lock_guard<std::mutex> lk(_mutex);
		return _code;
	}
private:
	std::atomic<bool>  _flag{false};
	mutable std::mutex _mutex;
	std::string        _description;
	int                _code = 0;
};

class OutputSerializer;

// Returned by EditFileMCPCore — decouples edit logic from MCP response emission.
struct MCPEditResult {
    bool ok;
    int error_code; // JSON-RPC error code on failure (-32002, -32603, …)
    std::string message; // result text on success, error description on failure
};

// Returned by ExcecuteToolMCPCore — decouples execution from MCP response emission.
struct MCPExecuteResult {
    bool        launched    = false; // false if the executable could not be spawned
    bool        timed_out   = false;
    int         exit_code   = 0;
    std::string stdout_text;
    std::string stderr_text;
    std::string launch_error; // non-empty when !launched
};

// Returned by GrepFileMCPCore — grep-style content search results for one file.
struct MCPGrepResult {
    std::string text;         // formatted grep-style output; empty when no matches
    int         match_count = 0;
    bool        is_binary   = false; // file contains null bytes — skipped
    std::string error;        // non-empty on I/O failure
};
#endif // __cplusplus

NS_ASSUME_NONNULL_BEGIN

typedef struct
{
	std::unordered_map<std::string, std::string> environment;
	ReplayError lastError;
	FileNode * __nullable fileTreeRoot;
	OutputSerializer* outputSerializer; // always non-null during execution
	dispatch_queue_t queue; // used only for serial execution
	intptr_t councurrencyLimit; //maximum number of tasks allowed to be executed concurrently. 0 = unlimited
	NSInteger actionCounter; //counter incremented with each serially created action
	NSString *batchName; //when running in server mode the batch name is provided for unique message port name
	CFMessagePortRef callbackPort; //the port to report back progress status and finish event
	bool concurrent;
	bool analyzeDependencies;
	bool verbose;
	bool dryRun;
	bool stopOnError;
	bool force;
	bool orderedOutput;
	bool mcpServer;
} ReplayContext;

typedef struct
{
	NSDictionary *settings;
	NSInteger index;
	std::string mcpRequestID; // raw JSON of the JSON-RPC id field; empty when not in MCP mode
} ActionContext;

typedef void (^action_handler_t)(__nullable dispatch_block_t action,
								NSArray<NSString*> * __nullable inputs,
								NSArray<NSString*> * __nullable mutatingInputs,
								NSArray<NSString*> * __nullable exclusiveInputs,
								NSArray<NSString*> * __nullable outputs);

NSDictionary * ActionDescriptionFromLine(const char *line, ssize_t linelen);
void HandleActionStep(NSDictionary *stepDescription, ReplayContext *context, action_handler_t actionHandler);

#ifdef __cplusplus

bool CloneItem(const std::string &fromPath, const std::string &toPath, ReplayContext *context, ActionContext *actionContext);
bool MoveItem(const std::string &fromPath, const std::string &toPath, ReplayContext *context, ActionContext *actionContext);
bool HardlinkItem(const std::string &fromPath, const std::string &toPath, ReplayContext *context, ActionContext *actionContext);
bool SymlinkItem(const std::string &fromPath, const std::string &linkPath, ReplayContext *context, ActionContext *actionContext);
bool CreateFile(const std::string &itemPath, const std::string &content, ReplayContext *context, ActionContext *actionContext);
bool CreateFileFromBlob(const std::string &itemPath, const std::string &base64Content, ReplayContext *context, ActionContext *actionContext);
bool CreateDirectory(const std::string &itemPath, ReplayContext *context, ActionContext *actionContext);
bool DeleteItem(const std::string &itemPath, ReplayContext *context, ActionContext *actionContext);
bool ReadFile(const std::string &filePath, ReplayContext *context, ActionContext *actionContext);
bool ListDirectory(const std::string &dirPath, ReplayContext *context, ActionContext *actionContext);
bool DirectoryTree(const std::string &dirPath, NSInteger maxDepth, ReplayContext *context, ActionContext *actionContext);
bool GetFileInfo(const std::string &path, ReplayContext *context, ActionContext *actionContext);
bool GlobFiles(NSString *rootDir, NSArray<NSString*> *globPatterns, NSArray<NSString*> *excludePatterns, NSInteger maxResults, ReplayContext *context, ActionContext *actionContext);
// edits: array of dicts with keys: oldText (required), newText, limit (default 1, 0=unlimited), regex, case-insensitive
// actionDryRun: show plan without writing (overrides nothing; stacks with context->dryRun)
bool EditFile(const std::string &filePath, NSArray<NSDictionary *> *edits, bool actionDryRun, ReplayContext *context, ActionContext *actionContext);
bool ExcecuteTool(const std::string &toolPath, const std::vector<std::string> &arguments, ReplayContext *context, ActionContext *actionContext);
bool Echo(const std::string &text, ReplayContext *context, ActionContext *actionContext);

// These functions return C++ structs and take C++ types — C linkage not possible.
MCPEditResult EditFileMCPCore(const std::string &filePath, NSArray<NSDictionary *> *edits, bool dryRun);
// workingDir: passed to NSTask setCurrentDirectoryPath; empty = inherited CWD.
// timeoutSeconds: SIGTERM at deadline, SIGKILL after 3s grace.
MCPExecuteResult ExcecuteToolMCPCore(const std::string &toolPath, const std::vector<std::string> &arguments,
                                      const std::string &workingDir, int timeoutSeconds);
// pattern: literal or POSIX ERE string. max_matches: stops counting (not formatting) at this limit.
MCPGrepResult GrepFileMCPCore(const std::string &filePath, const std::string &pattern,
                               bool use_regex, bool case_insensitive,
                               int context_lines, int max_matches);
#endif

NS_ASSUME_NONNULL_END
