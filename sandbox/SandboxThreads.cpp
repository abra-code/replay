//
//  SandboxThreads.cpp
//
//  See SandboxThreads.h.
//

#include "SandboxThreads.h"

#if defined(__linux__)
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <algorithm>
#endif

namespace sandbox
{

#if defined(__linux__)

// The thread's name from /proc/self/task/<id>/comm, or "?" when it cannot be read.
static std::string ThreadName(pid_t tid)
{
    char path[64];
    snprintf(path, sizeof(path), "/proc/self/task/%d/comm", (int)tid);
    FILE *file = fopen(path, "re");
    if (file == nullptr)
        return "?";
    char name[64] = {0};
    bool ok = (fgets(name, sizeof(name), file) != nullptr);
    fclose(file);
    if (!ok)
        return "?";
    size_t len = strlen(name);
    if (len > 0 && name[len - 1] == '\n')
        name[len - 1] = '\0';
    return name;
}

bool OnlyAllowedThreadsRunning(const std::vector<pid_t>& allowed, std::string& unexpected)
{
    unexpected.clear();
    pid_t self = (pid_t)syscall(SYS_gettid);

    DIR *dir = opendir("/proc/self/task");
    if (dir == nullptr)
    {
        unexpected = std::string("cannot list the threads in /proc/self/task: ") + strerror(errno);
        return false;
    }

    bool onlyAllowed = true;
    int readError = 0;
    while (true)
    {
        // readdir reports an error only through errno, and ThreadName's fopen below may
        // set errno too, so it is cleared right before each call.
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (entry == nullptr)
        {
            readError = errno;
            break;
        }

        // Entries are thread ids; "." and ".." are the only others.
        char *end = nullptr;
        long value = strtol(entry->d_name, &end, 10);
        if (end == entry->d_name || *end != '\0' || value <= 0)
            continue;
        pid_t tid = (pid_t)value;
        if (tid == self)
            continue;
        if (std::find(allowed.begin(), allowed.end(), tid) != allowed.end())
            continue;

        onlyAllowed = false;
        if (!unexpected.empty())
            unexpected += ", ";
        unexpected += std::to_string(tid) + " (" + ThreadName(tid) + ")";
    }
    closedir(dir);

    if (readError != 0)
    {
        unexpected = std::string("cannot list the threads in /proc/self/task: ") + strerror(readError);
        return false;
    }
    return onlyAllowed;
}

#else

bool OnlyAllowedThreadsRunning(const std::vector<pid_t>& allowed, std::string& unexpected)
{
    (void)allowed;
    unexpected.clear();
    return true;
}

#endif

}  // namespace sandbox
