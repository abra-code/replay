#include "ChildProcess.h"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <ctime>
#include <string>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

namespace ChildProcess
{

namespace
{

// Create a pipe with O_CLOEXEC on both ends so concurrent spawns don't
// inherit each other's write-ends — that's what would otherwise leave a
// pipe open in another process and stall the drain on this side.
int PipeCloexec(int fds[2])
{
    if(pipe(fds) != 0)
        return -1;
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    return 0;
}

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

Result Run(const Options &opts)
{
    Result res;

    if(opts.argv.empty())
    {
        res.launch_error = "ChildProcess::Run: argv is empty";
        return res;
    }

    std::vector<const char*> argv;
    argv.reserve(opts.argv.size() + 1);
    for(const auto &arg : opts.argv)
        argv.push_back(arg.c_str());
    argv.push_back(nullptr);

    const char *path = opts.argv[0].c_str();

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

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, &fa, &spawnattr,
                         const_cast<char* const*>(argv.data()), envp);
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
