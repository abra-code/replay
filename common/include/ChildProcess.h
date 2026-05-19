#pragma once
#include <cstddef>
#include <string>
#include <sys/types.h>
#include <vector>

// Unified posix_spawn wrapper. Replaces three near-duplicate spawn sites
// (dispatch, gate, replay execute) with one configurable entry point.
//
// Simple sites set just argv and a couple of bools; advanced sites turn on
// stdout/stderr capture, a timeout, working directory, and output cap.
//
// Drain is always poll(2)-based on the calling thread — no extra threads,
// no GCD pool pressure. This matters when many spawns run concurrently
// (the original GCD-based drain caused worker-thread starvation at scale).
namespace ChildProcess
{

struct Options
{
    // argv[0] is the executable path passed to posix_spawn.
    std::vector<std::string> argv;

    // Empty = inherit the parent's working directory.
    // Non-empty = posix_spawn_file_actions_addchdir_np(workingDir).
    std::string workingDir;

    // nullptr = inherit the global `environ`.
    char* const* envp = nullptr;

    // Redirect child's stdin from /dev/null (true) or inherit parent's (false).
    // Most tools want true so they don't accidentally consume the parent's stdin.
    bool stdinDevNull = true;

    // Capture stdout/stderr through pipes. When false the child inherits the
    // parent's corresponding fd.
    bool captureStdout = false;
    bool captureStderr = false;

    // 0 = uncapped. >0 = stop appending past this many bytes per stream and
    // append a "[output truncated at N KB]" marker.
    std::size_t maxOutputBytes = 0;

    // 0 = wait forever. >0 = SIGTERM the child at the deadline, give it
    // 3 seconds to exit, then SIGKILL.
    int timeoutSeconds = 0;

    // true = posix_spawn the child and return immediately without waitpid.
    // captureStdout/Err/timeoutSeconds are ignored in this mode.
    // Result.pid carries the spawned pid.
    bool detach = false;
};

struct Result
{
    bool launched   = false; // false if posix_spawn or pipe setup failed
    bool timed_out  = false; // true if the timeout elapsed before exit
    int  exit_code  = 0;     // -1 if the child died by signal (see term_signal)
    int  term_signal = 0;    // signal number when child was killed; 0 otherwise
    pid_t pid       = 0;     // valid when launched

    // Empty when launched == true. Formatted as "<context>: <strerror>".
    std::string launch_error;

    // Populated only when captureStdout/captureStderr were requested.
    std::string stdout_text;
    std::string stderr_text;
};

Result Run(const Options &opts);

} // namespace ChildProcess
