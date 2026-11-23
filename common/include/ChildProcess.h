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
    // argv[0] names the executable: a path when it contains a slash, otherwise a name
    // looked up with FindExecutable. The child gets argv[0] as given.
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

// The executable a command name stands for. A name containing a slash is returned as
// given. A name without one is looked up in the folders of PATH, in order (if PATH is
// not set, in /usr/bin and /bin); only absolute folders count, so an empty or relative
// entry, which would mean the current folder, is skipped. Returns the first regular file
// there that the user may execute, or an empty string.
std::string FindExecutable(const std::string &name);

Result Run(const Options &opts);

// From this call on, every child gets only descriptors 0 to 2 (as the options set them
// up); the parent's other descriptors stay behind, close-on-exec or not. replay and gate
// call it once their kernel sandbox is on: a descriptor their own caller left open
// (on a file outside the grants, say) would otherwise let a sandboxed command read or
// write through it, which the sandbox does not check. Unsandboxed runs keep passing
// descriptors on, as a classic make jobserver needs.
void CloseOtherDescriptorsInChildren();

// Linux: makes this process the subreaper of everything it starts, so a descendant that
// leaves its process group and session (setsid) is re-parented to this process rather
// than to the system, and ends every remaining descendant when this process exits
// normally (SIGTERM, then SIGKILL after a second). replay and gate call it once their
// kernel sandbox is on, so that nothing sandboxed outlives the run. Not when killed
// by a signal, which runs no exit handlers. macOS has no subreaper; there it does
// nothing.
void EndDescendantsAtExit();

} // namespace ChildProcess
