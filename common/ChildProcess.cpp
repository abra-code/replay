#include "ChildProcess.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>
#if defined(__linux__)
#include <cstdio>
#include <cstdlib>
#include <dirent.h>
#include <mutex>
#include <set>
#include <sys/prctl.h>
#endif

extern char **environ;

namespace ChildProcess
{

namespace
{

// Set by CloseOtherDescriptorsInChildren.
std::atomic<bool> gCloseOtherDescriptors(false);

// Linux: closing the other descriptors needs posix_spawn_file_actions_addclosefrom_np
// (glibc 2.34). Without it (another C library) the build still works, but Run refuses
// to start a child once the switch is on, rather than pass descriptors on.
#if defined(__linux__) && defined(__GLIBC__) && ((__GLIBC__ > 2) || (__GLIBC_MINOR__ >= 34))
#define REPLAY_HAS_ADDCLOSEFROM 1
#else
#define REPLAY_HAS_ADDCLOSEFROM 0
#endif

// Create a pipe with O_CLOEXEC on both ends so concurrent spawns don't
// inherit each other's write-ends — that's what would otherwise leave a
// pipe open in another process and stall the drain on this side.
// Linux sets the flag in the same call; macOS has no pipe2, so a spawn on
// another thread between pipe and fcntl can still inherit the ends there
// (unless the children get only descriptors 0 to 2).
int PipeCloexec(int fds[2])
{
#if defined(__linux__)
    return pipe2(fds, O_CLOEXEC);
#else
    if(pipe(fds) != 0)
        return -1;
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    return 0;
#endif
}

#if defined(__APPLE__)
// POSIX_SPAWN_CLOEXEC_DEFAULT closes every descriptor no file action names, so a
// standard descriptor the child should inherit as it is must be named; a closed one
// cannot be (the spawn would fail), and stays closed in the child as before.
// A close-on-exec one is not named either: an inherit action would clear the flag, and
// without the sandbox (and on Linux) the child does not get it.
void InheritIfOpen(posix_spawn_file_actions_t *fa, int fd)
{
    int flags = fcntl(fd, F_GETFD);
    if((flags != -1) && ((flags & FD_CLOEXEC) == 0))
        posix_spawn_file_actions_addinherit_np(fa, fd);
}
#endif

void CloseIfOpen(int &fd)
{
    if(fd >= 0)
    {
        close(fd);
        fd = -1;
    }
}

// Monotonic milliseconds for deadline math. CLOCK_MONOTONIC so wall-clock
// adjustments can't extend or shorten a timeout.
long long NowMillis()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// Drain up to two pipe read ends until both hit EOF or the deadline expires.
// deadlineMillis < 0 means no deadline. On deadline expiry returns false and
// leaves any still-open fds open for the caller to close after killing the child.
bool DrainPipes(int &outFd, int &errFd,
                std::string *outBuf, std::string *errBuf,
                std::size_t maxBytes,
                long long deadlineMillis)
{
    struct pollfd fds[2];
    fds[0].fd = outFd; fds[0].events = POLLIN; fds[0].revents = 0;
    fds[1].fd = errFd; fds[1].events = POLLIN; fds[1].revents = 0;

    char tmp[4096];
    while(fds[0].fd >= 0 || fds[1].fd >= 0)
    {
        int timeoutMs = -1;
        if(deadlineMillis >= 0)
        {
            long long remaining = deadlineMillis - NowMillis();
            if(remaining <= 0)
                return false;
            timeoutMs = (int)std::min<long long>(remaining, 1000 * 60 * 60); // cap at 1h to fit int
        }

        int n;
        do { n = poll(fds, 2, timeoutMs); } while(n < 0 && errno == EINTR);
        if(n == 0)
            return false; // timed out
        if(n < 0)
            break;        // unexpected poll error; stop draining

        for(int i = 0; i < 2; i++)
        {
            if(fds[i].fd < 0 || fds[i].revents == 0)
                continue;

            std::string *buf = (i == 0) ? outBuf : errBuf;
            if(fds[i].revents & POLLIN)
            {
                ssize_t r = read(fds[i].fd, tmp, sizeof(tmp));
                if(r > 0)
                {
                    if(buf != nullptr)
                    {
                        if(maxBytes == 0 || buf->size() < maxBytes)
                        {
                            std::size_t room = (maxBytes == 0) ? (std::size_t)r
                                                              : std::min((std::size_t)r, maxBytes - buf->size());
                            buf->append(tmp, room);
                        }
                    }
                    continue;
                }
            }
            // EOF or POLLHUP/POLLERR — close this side.
            close(fds[i].fd);
            fds[i].fd = -1;
            if(i == 0) outFd = -1; else errFd = -1;
        }
    }
    return true;
}

void TruncateMarker(std::string &s, std::size_t maxBytes)
{
    if(maxBytes > 0 && s.size() >= maxBytes)
    {
        s.resize(maxBytes);
        s += "\n[output truncated at ";
        s += std::to_string(maxBytes / 1024);
        s += " KB]";
    }
}

// Poll-with-WNOHANG until the child is reaped or the deadline expires.
// Used after SIGKILL so the call returns in bounded time even when signal
// delivery is suppressed (e.g., a sandbox profile that denies `signal`).
//
// Each iteration: one non-blocking waitpid + one 20ms sleep. EINTR and
// "child still running" both fall through to the sleep, so a flurry of
// signals can't make this spin.
bool WaitForExit(pid_t pid, int *statusOut, long long deadlineMillis)
{
    for(;;)
    {
        int status = 0;
        pid_t r = waitpid(pid, &status, WNOHANG);
        if(r == pid)
        {
            if(statusOut != nullptr)
                *statusOut = status;
            return true;
        }
        if(r < 0 && errno != EINTR)
            return false; // ECHILD or similar — nothing left to reap
        if(NowMillis() >= deadlineMillis)
            return false;
        struct timespec ts = {0, 20 * 1000 * 1000}; // 20 ms
        nanosleep(&ts, nullptr);
    }
}

} // namespace

void CloseOtherDescriptorsInChildren()
{
    gCloseOtherDescriptors.store(true);
}

#if defined(__linux__)
namespace
{

// The processes whose parent is this one, from /proc/<pid>/stat (field 4, after the
// command name, which is in parentheses and may itself contain ") "). Zombies included:
// they are reaped by the caller.
std::vector<pid_t> DirectChildren()
{
    std::vector<pid_t> children;
    const pid_t self = getpid();
    DIR *proc = opendir("/proc");
    if(proc == nullptr)
        return children;
    while(struct dirent *entry = readdir(proc))
    {
        char *end = nullptr;
        long pid = strtol(entry->d_name, &end, 10);
        if((end == entry->d_name) || (*end != '\0') || (pid <= 0))
            continue;
        char path[64];
        snprintf(path, sizeof(path), "/proc/%ld/stat", pid);
        FILE *f = fopen(path, "re");
        if(f == nullptr)
            continue; // gone meanwhile
        char line[1024];
        bool read = (fgets(line, sizeof(line), f) != nullptr);
        fclose(f);
        if(!read)
            continue;
        const char *close = strrchr(line, ')');
        char state = 0;
        long ppid = 0;
        if((close != nullptr) && (sscanf(close + 1, " %c %ld", &state, &ppid) == 2) && (ppid == self))
            children.push_back((pid_t)pid);
    }
    closedir(proc);
    return children;
}

// While this process is a subreaper: the children a Run call waits for, which only
// that call may reap. Changed under gChildrenMutex, which posix_spawn also runs under,
// so a child that exits at once is in the set before anyone can see it exit.
std::atomic<bool> gSubreaper(false);
std::mutex gChildrenMutex;
std::set<pid_t> gRunChildren;

// A subreaper adopts every orphaned descendant, and an adopted one that exits stays a
// zombie until this process reaps it (before, the system did). Called after each Run:
// reaps exited children that no Run waits for. Stops at one that a Run waits for,
// which that Run reaps soon; the rest are reaped after the next Run.
void ReapAdoptedOrphans()
{
    std::lock_guard<std::mutex> lock(gChildrenMutex);
    for(int i = 0; i < 64; i++)
    {
        siginfo_t info;
        memset(&info, 0, sizeof(info));
        if((waitid(P_ALL, 0, &info, WEXITED | WNOHANG | WNOWAIT) != 0) || (info.si_pid == 0))
            return;
        if(gRunChildren.count(info.si_pid) != 0)
            return;
        waitpid(info.si_pid, nullptr, WNOHANG);
    }
}

// Reaps the children that have exited, without waiting.
void ReapExited()
{
    while(waitpid(-1, nullptr, WNOHANG) > 0)
    {
    }
}

void EndRemainingDescendants()
{
    std::vector<pid_t> children = DirectChildren();
    if(children.empty())
        return;
    std::set<pid_t> asked;
    for(pid_t pid : children)
    {
        kill(pid, SIGTERM);
        asked.insert(pid);
    }
    // A second for them to finish; their own children are re-parented here as they go,
    // and are asked too.
    long long deadline = NowMillis() + 1000;
    while(NowMillis() < deadline)
    {
        ReapExited();
        children = DirectChildren();
        if(children.empty())
            return;
        for(pid_t pid : children)
        {
            if(asked.insert(pid).second)
                kill(pid, SIGTERM);
        }
        usleep(20000);
    }
    // Then SIGKILL, round by round: each one killed hands its children to this process.
    for(int round = 0; round < 100; round++)
    {
        children = DirectChildren();
        if(children.empty())
            return;
        for(pid_t pid : children)
            kill(pid, SIGKILL);
        usleep(10000);
        ReapExited();
    }
}

} // namespace
#endif

void EndDescendantsAtExit()
{
#if defined(__linux__)
    static std::atomic<bool> registered(false);
    if(registered.exchange(true))
        return;
    if(prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0)
    {
        fprintf(stderr, "warning: cannot become the subreaper of the commands (%s): a process that "
                        "leaves its session with setsid can outlive this run\n", strerror(errno));
        return;
    }
    gSubreaper.store(true);
    std::atexit(EndRemainingDescendants);
#endif
}

std::string FindExecutable(const std::string &name)
{
    if(name.empty() || (name.find('/') != std::string::npos))
        return name;

    const char *pathVar = getenv("PATH");
    std::string folders = (pathVar != nullptr) ? pathVar : "/usr/bin:/bin";
    size_t start = 0;
    while(start <= folders.size())
    {
        size_t end = folders.find(':', start);
        if(end == std::string::npos)
            end = folders.size();
        std::string folder = folders.substr(start, end - start);
        start = end + 1;

        // An empty or relative entry means the current folder: a tool planted there
        // must not run in place of the one the user expects.
        if(folder.empty() || (folder[0] != '/'))
            continue;

        std::string candidate = folder;
        if(candidate.back() != '/')
            candidate += '/';
        candidate += name;
        struct stat info;
        if((stat(candidate.c_str(), &info) == 0) && S_ISREG(info.st_mode)
           && (access(candidate.c_str(), X_OK) == 0))
            return candidate;
    }
    return {};
}

Result Run(const Options &opts)
{
    Result res;

    if(opts.argv.empty())
    {
        res.launch_error = "ChildProcess::Run: argv is empty";
        return res;
    }
#if defined(__linux__) && !REPLAY_HAS_ADDCLOSEFROM
    if(gCloseOtherDescriptors.load())
    {
        res.launch_error = "ChildProcess::Run: under the sandbox a child must not get the other "
                           "descriptors, which needs posix_spawn_file_actions_addclosefrom_np (glibc 2.34)";
        return res;
    }
#endif

    std::vector<const char*> argv;
    argv.reserve(opts.argv.size() + 1);
    for(const auto &arg : opts.argv)
        argv.push_back(arg.c_str());
    argv.push_back(nullptr);

    const std::string executable = FindExecutable(opts.argv[0]);
    if(executable.empty())
    {
        res.launch_error = opts.argv[0].empty() ? std::string("the command name is empty")
                                                : opts.argv[0] + ": not found in PATH";
        return res;
    }
    const char *path = executable.c_str();

    int outPipe[2] = {-1, -1};
    int errPipe[2] = {-1, -1};
    const bool wantOut = opts.captureStdout && !opts.detach;
    const bool wantErr = opts.captureStderr && !opts.detach;

    if(wantOut && PipeCloexec(outPipe) != 0)
    {
        res.launch_error = std::string("pipe(stdout): ") + strerror(errno);
        return res;
    }
    if(wantErr && PipeCloexec(errPipe) != 0)
    {
        res.launch_error = std::string("pipe(stderr): ") + strerror(errno);
        CloseIfOpen(outPipe[0]); CloseIfOpen(outPipe[1]);
        return res;
    }

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);

    if(opts.stdinDevNull)
        posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);

    if(wantOut)
    {
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], STDOUT_FILENO);
        // Close both ends in the child after dup2 — the child only needs the
        // duped STDOUT_FILENO. Keeping originals open would leave extra writers
        // and prevent EOF when the child exits.
        posix_spawn_file_actions_addclose(&fa, outPipe[1]);
        posix_spawn_file_actions_addclose(&fa, outPipe[0]);
    }
    if(wantErr)
    {
        posix_spawn_file_actions_adddup2(&fa, errPipe[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&fa, errPipe[1]);
        posix_spawn_file_actions_addclose(&fa, errPipe[0]);
    }

    if(!opts.workingDir.empty())
        posix_spawn_file_actions_addchdir_np(&fa, opts.workingDir.c_str());

    char* const* envp = (opts.envp != nullptr) ? opts.envp : environ;

    // Put the child in its own process group so a timeout-driven killpg() can
    // signal the whole subtree (shell + every descendant) rather than just the
    // immediate child. Without this, `/bin/sh -c "sleep 100"` would leave the
    // sleep alive holding the pipe write end after we killed the shell.
    //
    // Also reset the child's signal mask to empty. We are typically called on
    // a libdispatch worker thread, which blocks SIGTERM (and most other
    // catchable signals) — without an explicit reset the child inherits that
    // mask and silently ignores SIGTERM, forcing every timeout to fall through
    // to the SIGKILL path 3 seconds later.
    posix_spawnattr_t spawnattr;
    posix_spawnattr_init(&spawnattr);
    short spawnFlags = 0;
    posix_spawnattr_getflags(&spawnattr, &spawnFlags);
    spawnFlags |= POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK;
    posix_spawnattr_setflags(&spawnattr, spawnFlags);
    posix_spawnattr_setpgroup(&spawnattr, 0); // 0 = new pgrp, pgid == child pid
    sigset_t emptyMask;
    sigemptyset(&emptyMask);
    posix_spawnattr_setsigmask(&spawnattr, &emptyMask);

    // Under the sandbox, only descriptors 0 to 2 reach the child (see the header).
    // After the dup2 actions above, so the standard descriptors they set stay open.
    if(gCloseOtherDescriptors.load())
    {
#if defined(__APPLE__)
        if(!opts.stdinDevNull)
            InheritIfOpen(&fa, STDIN_FILENO);
        if(!wantOut)
            InheritIfOpen(&fa, STDOUT_FILENO);
        if(!wantErr)
            InheritIfOpen(&fa, STDERR_FILENO);
        spawnFlags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
        posix_spawnattr_setflags(&spawnattr, spawnFlags);
#elif REPLAY_HAS_ADDCLOSEFROM
        posix_spawn_file_actions_addclosefrom_np(&fa, STDERR_FILENO + 1);
#endif
    }

    pid_t pid = 0;
    int rc;
#if defined(__linux__)
    if(gSubreaper.load())
    {
        std::lock_guard<std::mutex> lock(gChildrenMutex);
        rc = posix_spawn(&pid, path, &fa, &spawnattr,
                         const_cast<char* const*>(argv.data()), envp);
        if((rc == 0) && !opts.detach)
            gRunChildren.insert(pid);
    }
    else
#endif
    {
        rc = posix_spawn(&pid, path, &fa, &spawnattr,
                         const_cast<char* const*>(argv.data()), envp);
    }
    posix_spawnattr_destroy(&spawnattr);
    posix_spawn_file_actions_destroy(&fa);

    // Parent closes write ends so the child holds the only remaining writers
    // and our reads see EOF when the child exits.
    CloseIfOpen(outPipe[1]);
    CloseIfOpen(errPipe[1]);

    if(rc != 0)
    {
        CloseIfOpen(outPipe[0]);
        CloseIfOpen(errPipe[0]);
        res.launch_error = std::string("posix_spawn(") + path + "): " + strerror(rc);
        return res;
    }

    res.launched = true;
    res.pid      = pid;

    if(opts.detach)
        return res;

    long long deadlineMillis = -1;
    if(opts.timeoutSeconds > 0)
        deadlineMillis = NowMillis() + (long long)opts.timeoutSeconds * 1000;

    std::string outBuf, errBuf;
    bool finished = DrainPipes(outPipe[0], errPipe[0],
                               wantOut ? &outBuf : nullptr,
                               wantErr ? &errBuf : nullptr,
                               opts.maxOutputBytes,
                               deadlineMillis);

    if(!finished)
    {
        res.timed_out = true;
        // Signal the whole process group, not just the immediate child:
        // `/bin/sh -c "cmd"` may fork descendants that keep the pipe write
        // end open. The child is its own pgrp leader (see posix_spawnattr
        // above) so pid doubles as the pgid.
        killpg(pid, SIGTERM);
        long long grace = NowMillis() + 3000;
        if(!DrainPipes(outPipe[0], errPipe[0],
                       wantOut ? &outBuf : nullptr,
                       wantErr ? &errBuf : nullptr,
                       opts.maxOutputBytes,
                       grace))
        {
            killpg(pid, SIGKILL);
            // Bounded drain — SIGKILL'd processes die promptly, so give them
            // a brief window to flush, then move on. The previous infinite
            // timeout here hung indefinitely whenever signal delivery was
            // suppressed (e.g. a sandbox profile that denies `signal`).
            long long finalDrainEnd = NowMillis() + 500;
            DrainPipes(outPipe[0], errPipe[0],
                       wantOut ? &outBuf : nullptr,
                       wantErr ? &errBuf : nullptr,
                       opts.maxOutputBytes,
                       finalDrainEnd);
        }
    }

    // Defensive: drain ran to EOF normally, but if a poll error caused early
    // exit some fds may still be open.
    CloseIfOpen(outPipe[0]);
    CloseIfOpen(errPipe[0]);

    int status = 0;
    bool reaped;
    if(res.timed_out)
    {
        // After SIGKILL the child should be reapable within milliseconds.
        // Cap the wait so Run() returns in bounded time even if the kill
        // never landed (sandbox denial, etc.) — the alternative is to hang
        // here forever on a blocking waitpid.
        long long waitDeadline = NowMillis() + 2000;
        reaped = WaitForExit(pid, &status, waitDeadline);
    }
    else
    {
        pid_t r;
        do { r = waitpid(pid, &status, 0); } while(r < 0 && errno == EINTR);
        reaped = (r == pid);
    }
#if defined(__linux__)
    if(gSubreaper.load())
    {
        {
            std::lock_guard<std::mutex> lock(gChildrenMutex);
            gRunChildren.erase(pid);
        }
        ReapAdoptedOrphans();
    }
#endif

    if(reaped && WIFEXITED(status))
    {
        res.exit_code = WEXITSTATUS(status);
    }
    else if(reaped && WIFSIGNALED(status))
    {
        res.exit_code = -1;
        res.term_signal = WTERMSIG(status);
    }
    else
    {
        res.exit_code = -1;
    }

    if(wantOut)
    {
        TruncateMarker(outBuf, opts.maxOutputBytes);
        res.stdout_text = std::move(outBuf);
    }
    if(wantErr)
    {
        TruncateMarker(errBuf, opts.maxOutputBytes);
        res.stderr_text = std::move(errBuf);
    }
    return res;
}

} // namespace ChildProcess
