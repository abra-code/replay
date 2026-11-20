//
//  SandboxLandlock.cpp
//
//  See SandboxLandlock.h. Linux only; empty elsewhere.
//

#if defined(__linux__)

#include "SandboxLandlock.h"
#include "SandboxThreads.h"
#include "FileHelpers.h"
#include "Platform.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>

// System call numbers, the same on every architecture (asm-generic and x86_64), in
// case the C library headers predate Landlock.
#ifndef __NR_landlock_create_ruleset
#define __NR_landlock_create_ruleset 444
#endif
#ifndef __NR_landlock_add_rule
#define __NR_landlock_add_rule 445
#endif
#ifndef __NR_landlock_restrict_self
#define __NR_landlock_restrict_self 446
#endif

namespace sandbox
{
namespace landlock
{

namespace
{

constexpr uint32_t kCreateRulesetVersion = 1U << 0;
constexpr uint32_t kRestrictSelfTsync = 1U << 3; // ABI 8
constexpr int kRulePathBeneath = 1;

// The kernel's struct landlock_ruleset_attr up to the fields this code uses; it is
// passed with the size the running ABI knows.
struct RulesetAttr
{
    uint64_t handledAccessFs;
    uint64_t handledAccessNet; // ABI 4
    uint64_t scoped;           // ABI 6
};

struct PathBeneathAttr
{
    uint64_t allowedAccess;
    int32_t parentFd;
} __attribute__((packed));

// Rights that apply to a file, as opposed to a folder: a rule on a file may grant
// only these (the kernel refuses the others with EINVAL).
constexpr uint64_t kFileRights = kExecute | kWriteFile | kReadFile | kTruncate | kIoctlDev;

// Every right the ABI knows, except IOCTL_DEV, which the sandbox leaves unhandled.
uint64_t HandledFor(int abi)
{
    uint64_t rights = kExecute | kWriteFile | kReadFile | kReadDir | kRemoveDir | kRemoveFile
                    | kMakeChar | kMakeDir | kMakeReg | kMakeSock | kMakeFifo | kMakeBlock | kMakeSym;
    if (abi >= 2)
        rights |= kRefer;
    if (abi >= 3)
        rights |= kTruncate;
    if (abi >= 9)
        rights |= kResolveUnix;
    return rights;
}

// What each kind of grant allows (design section 4), before masking with the ABI.
constexpr uint64_t kReadOnlyDir  = kReadFile | kReadDir;
constexpr uint64_t kReadWriteDir = kReadFile | kReadDir | kWriteFile | kRemoveDir | kRemoveFile
                                 | kMakeDir | kMakeReg | kMakeSock | kMakeFifo | kMakeSym
                                 | kRefer | kTruncate | kResolveUnix;
constexpr uint64_t kReadOnlyFile  = kReadFile;
constexpr uint64_t kReadWriteFile = kReadFile | kWriteFile | kTruncate;

bool IsUnder(const std::string& path, const std::string& dir)
{
    if (dir == "/")
        return !path.empty() && path[0] == '/';
    return path == dir
        || (path.size() > dir.size() && path.compare(0, dir.size(), dir) == 0 && path[dir.size()] == '/');
}

bool CoveredBy(const std::string& path, const std::vector<Rule>& rules, uint64_t access)
{
    for (const auto& rule : rules)
    {
        if (rule.isDirectory && (rule.access & access) == access && IsUnder(path, rule.path))
            return true;
    }
    return false;
}

std::string ParentOf(const std::string& path)
{
    size_t slash = path.rfind('/');
    if (slash == std::string::npos || slash == 0)
        return "/";
    return path.substr(0, slash);
}

// Folders of the baseline (design section 5), read-only. Links (on merged-/usr
// systems /bin, /lib... point into /usr) resolve to a folder already listed.
const char *const kBaselineReadOnlyDirs[] = {
    "/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/etc", "/proc", "/sys/devices/system/cpu",
};

// Devices of the baseline, read and write.
const char *const kBaselineDevices[] = {
    "/dev/null", "/dev/zero", "/dev/full", "/dev/random", "/dev/urandom", "/dev/tty",
};

// Folders a missing write path must never widen to (design section 7): the root,
// the home folder, and the baseline's own folders.
bool TooBroadToGrantInstead(const std::string& dir)
{
    if (dir == "/")
        return true;
    const char *home = getenv("HOME");
    if (home != nullptr && home[0] != '\0' && dir == file_helpers::resolve_literal_path(home))
        return true;
    // Compared canonically: on merged-/usr systems /bin is /usr/bin, and a missing
    // /bin/x/y must not widen to /usr/bin either.
    for (const char *base : kBaselineReadOnlyDirs)
    {
        if (dir == base || dir == file_helpers::resolve_literal_path(base))
            return true;
    }
    for (const char *other : {"/dev", "/sys", "/tmp", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/lib32", "/usr/lib64"})
    {
        if (dir == other || dir == file_helpers::resolve_literal_path(other))
            return true;
    }
    return false;
}

// Adds rules, keeping only paths not already covered with the same rights. Sorted so
// that a folder comes before what is beneath it.
void AddDeduplicated(std::vector<std::string> paths, uint64_t dirAccess, uint64_t fileAccess,
                     const char *why, std::vector<Rule>& rules)
{
    std::sort(paths.begin(), paths.end());
    paths.erase(std::unique(paths.begin(), paths.end()), paths.end());
    for (const auto& path : paths)
    {
        struct stat st;
        if (stat(path.c_str(), &st) != 0)
            continue; // checked by the caller; vanished since
        bool isDir = S_ISDIR(st.st_mode);
        uint64_t access = isDir ? dirAccess : fileAccess;
        if (CoveredBy(path, rules, access))
            continue;
        rules.push_back({path, access, isDir, why});
    }
}

// What the links directly in /etc point to (design section 5). Landlock judges the
// resolved path, so a link whose target lies outside the other rules leaves that /etc
// entry unreadable. The usual case: /etc/resolv.conf links into /run on systems with
// systemd-resolved (Ubuntu, Fedora), NetworkManager or resolvconf, and without its
// target a sandboxed program cannot look up host names. A target file under /run is
// granted with its folder (not /run itself, nor a folder in /run/user): those services
// replace the file with a new one, and a rule binds to the file's inode at the time it
// is added. Any other target is granted alone. Never granted this way: "/", the
// folders TooBroadToGrantInstead names, and a folder that is in /run/user or holds it.
std::vector<std::string> EtcLinkTargets()
{
    std::vector<std::string> targets;
    DIR *etc = opendir("/etc");
    if (etc == nullptr)
        return targets;
    struct dirent *entry;
    while ((entry = readdir(etc)) != nullptr)
    {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;
        std::string link = std::string("/etc/") + entry->d_name;
        struct stat st;
        if (lstat(link.c_str(), &st) != 0 || !S_ISLNK(st.st_mode))
            continue;
        char resolved[PATH_MAX];
        if (realpath(link.c_str(), resolved) == nullptr || stat(resolved, &st) != 0)
            continue; // dangling: nothing to read
        std::string target = resolved;
        if (target == "/" || TooBroadToGrantInstead(target))
            continue;
        // Not a folder in /run/user, nor one holding it: those are the users' own
        // runtime folders, and hold credentials (for example containers/auth.json).
        if (S_ISDIR(st.st_mode) && (IsUnder(target, "/run/user") || IsUnder("/run/user", target)))
            continue;
        if (!S_ISDIR(st.st_mode))
        {
            std::string dir = ParentOf(target);
            if (dir != "/run" && IsUnder(dir, "/run") && !IsUnder(dir, "/run/user") && !TooBroadToGrantInstead(dir))
                target = dir;
        }
        targets.push_back(target);
    }
    closedir(etc);
    return targets;
}

// Folders of the shared libraries this process has mapped (from /proc/self/maps)
// that the baseline does not cover: the Swift runtime may live outside /usr (D2).
std::vector<std::string> MappedLibraryDirs()
{
    std::vector<std::string> dirs;
    FILE *maps = fopen("/proc/self/maps", "re");
    if (maps == nullptr)
        return dirs;
    char line[PATH_MAX + 256];
    while (fgets(line, sizeof(line), maps) != nullptr)
    {
        // A line too long for the buffer (a path near PATH_MAX) is skipped whole: its
        // remainder would otherwise read as another line.
        if (strchr(line, '\n') == nullptr)
        {
            int c;
            while ((c = fgetc(maps)) != EOF && c != '\n')
                ;
            continue;
        }
        // "start-end perms offset dev inode path": only executable mappings are code,
        // not data files the process happens to map.
        char perms[8] = {0};
        if (sscanf(line, "%*s %7s", perms) != 1 || strchr(perms, 'x') == nullptr)
            continue;
        char *path = strchr(line, '/');
        if (path == nullptr)
            continue;
        size_t len = strlen(path);
        if (len > 0 && path[len - 1] == '\n')
            path[--len] = '\0';
        if (strstr(path, " (deleted)") != nullptr)
            continue;
        if (strstr(path, ".so") == nullptr)
            continue;
        char resolved[PATH_MAX];
        if (realpath(path, resolved) == nullptr)
            continue;
        // A library directly in "/" (LD_PRELOAD=/x.so) must not grant the whole file
        // system (design section 4: a grant of "/" is refused).
        std::string dir = ParentOf(resolved);
        if (dir == "/")
            continue;
        dirs.push_back(dir);
    }
    fclose(maps);
    return dirs;
}

}  // namespace


int Abi(int *error)
{
    long abi = syscall(__NR_landlock_create_ruleset, nullptr, 0, kCreateRulesetVersion);
    if (abi < 0)
    {
        if (error != nullptr)
            *error = errno;
        return -1;
    }
    return (int)abi;
}


bool BuildRules(const Config& config, int abi, RuleSet& out, std::string& error)
{
    RuleSet result;
    result.abi = abi;
    result.handledAccess = HandledFor(abi);
    result.scoped = (abi >= 6) ? kScopeSignal : 0;
    // Abstract Unix sockets have no path, so the path right of ABI 9 does not cover
    // them; the scope limits connecting to sockets made inside the sandbox. Only when
    // Unix sockets are limited (the MCP server): from ABI 9 it is what keeps a command
    // from, for example, the X server's abstract socket. Below ABI 9 the filter denies
    // creating Unix sockets anyway, and with the network denied it does on every ABI.
    if (config.deny_unix_sockets && abi >= 6)
        result.scoped |= kScopeAbstractUnix;

    // 1. Write grants. A missing path falls back to its nearest existing folder, but
    //    never to one too broad to grant in its place.
    std::vector<std::string> writes;
    for (const auto& raw : config.read_write)
    {
        if (raw.empty())
            continue;
        std::string path = file_helpers::resolve_literal_path(raw);
        if (path == "/")
        {
            result.warnings.push_back("warning: sandbox path \"" + raw + "\" resolves to \"/\" and was dropped; "
                                      "granting access to the filesystem root is not allowed");
            continue;
        }
        struct stat st;
        if (stat(path.c_str(), &st) == 0)
        {
            writes.push_back(path);
            continue;
        }
        std::string existing = ParentOf(path);
        while (existing != "/" && stat(existing.c_str(), &st) != 0)
            existing = ParentOf(existing);
        if (existing != "/" && !S_ISDIR(st.st_mode))
        {
            error = "sandbox write path \"" + path + "\" cannot exist: \"" + existing + "\" is a file, not a folder";
            return false;
        }
        if (TooBroadToGrantInstead(existing))
        {
            error = "sandbox write path \"" + path + "\" does not exist, and its nearest existing folder \""
                  + existing + "\" is too broad to grant in its place; create \"" + path + "\" first";
            return false;
        }
        result.warnings.push_back("warning: sandbox write path \"" + path + "\" does not exist yet; granting "
                                  "its nearest existing folder \"" + existing + "\" instead");
        writes.push_back(existing);
    }
    AddDeduplicated(writes, kReadWriteDir, kReadWriteFile, "granted", result.rules);

    // 2. Read grants: those inside a write grant are covered; a missing one is refused.
    std::vector<std::string> reads;
    for (const auto& raw : config.read_only)
    {
        if (raw.empty())
            continue;
        std::string path = file_helpers::resolve_literal_path(raw);
        if (path == "/")
        {
            result.warnings.push_back("warning: sandbox path \"" + raw + "\" resolves to \"/\" and was dropped; "
                                      "granting access to the filesystem root is not allowed");
            continue;
        }
        if (CoveredBy(path, result.rules, kReadFile))
            continue;
        struct stat st;
        if (stat(path.c_str(), &st) != 0)
        {
            error = "sandbox read path \"" + path + "\" does not exist; on Linux every read path must exist "
                    "when the sandbox starts";
            return false;
        }
        reads.push_back(path);
    }
    AddDeduplicated(reads, kReadOnlyDir, kReadOnlyFile, "granted", result.rules);

    // 3. The baseline (design section 5).
    if (config.import_baseline)
    {
        std::vector<std::string> baseline;
        for (const char *dir : kBaselineReadOnlyDirs)
        {
            char resolved[PATH_MAX];
            struct stat st;
            if (realpath(dir, resolved) != nullptr && stat(resolved, &st) == 0 && S_ISDIR(st.st_mode))
                baseline.push_back(resolved);
        }
        for (const auto& dir : MappedLibraryDirs())
            baseline.push_back(dir);
        AddDeduplicated(baseline, kReadOnlyDir, kReadOnlyFile, "baseline", result.rules);
        // After the folders above, so that a link into /usr or /proc adds no rule.
        AddDeduplicated(EtcLinkTargets(), kReadOnlyDir, kReadOnlyFile, "baseline: a link in /etc", result.rules);

        std::vector<std::string> devices;
        for (const char *device : kBaselineDevices)
        {
            struct stat st;
            if (stat(device, &st) == 0)
                devices.push_back(device);
        }
        AddDeduplicated(devices, kReadWriteFile, kReadWriteFile, "baseline", result.rules);

        // The terminals on descriptors 0 to 2, so that opening /dev/stdin or /dev/stderr
        // works when they are one. Only those: all of /dev/pts would let a command read
        // what the user types into another terminal and write into it (threat model
        // P-F6); this process can use these through its descriptors anyway. The
        // dangerous terminal ioctls are denied separately (design section 6).
        std::vector<std::string> terminals;
        for (int fd = 0; fd <= 2; fd++)
        {
            char name[PATH_MAX];
            if (isatty(fd) && ttyname_r(fd, name, sizeof(name)) == 0)
                terminals.push_back(name);
        }
        AddDeduplicated(terminals, kReadFile | kWriteFile, kReadFile | kWriteFile,
                        "baseline: the terminal on descriptor 0, 1 or 2", result.rules);
    }

    // 4. Running programs anywhere (design section 4).
    if (config.allow_exec)
        result.rules.push_back({"/", kExecute, true, "allow_exec"});

    for (auto& rule : result.rules)
    {
        rule.access &= result.handledAccess;
        if (!rule.isDirectory)
            rule.access &= kFileRights;
    }

    out = std::move(result);
    return true;
}


std::string Describe(const RuleSet& ruleset)
{
    std::string text = "Sandbox (Linux Landlock, ABI " + std::to_string(ruleset.abi) + "):\n";
    for (const auto& rule : ruleset.rules)
    {
        const char *kind;
        if (rule.access == kExecute)
            kind = "execute";
        else if (rule.access & kWriteFile)
            kind = "read-write";
        else
            kind = "read-only";
        text += "  ";
        text += kind;
        text += ": ";
        text += rule.path;
        text += "  [";
        text += rule.why;
        text += "]\n";
    }
    text += "Not covered by the sandbox: file metadata (stat, chmod, chown, timestamps) and device ioctls";
    if (ruleset.abi < 6)
        text += ", signals to other processes";
    if (ruleset.abi < 9)
        text += ", connecting to Unix sockets by path";
    text += ".\n";
    return text;
}


bool Apply(const RuleSet& ruleset, const std::vector<pid_t>& allowedThreads, std::string& error)
{
    // A thread already running stays outside a ruleset applied to the calling thread
    // only. From ABI 8 the kernel can apply it to all threads at once; below that, or
    // if it refuses, no thread other than the allowed ones may be running.
    bool allThreads = (ruleset.abi >= 8);
    if (!allThreads)
    {
        std::string unexpected;
        if (!OnlyAllowedThreadsRunning(allowedThreads, unexpected))
        {
            error = "other threads are running and would stay outside the sandbox: " + unexpected;
            return false;
        }
    }

    RulesetAttr attr = {ruleset.handledAccess, 0, ruleset.scoped};
    size_t attrSize = (ruleset.abi >= 6) ? sizeof(RulesetAttr) : (ruleset.abi >= 4 ? 2 * sizeof(uint64_t) : sizeof(uint64_t));
    int rulesetFd = (int)syscall(__NR_landlock_create_ruleset, &attr, attrSize, 0);
    if (rulesetFd < 0)
    {
        error = std::string("cannot create the Landlock ruleset: ") + strerror(errno);
        return false;
    }

    for (const auto& rule : ruleset.rules)
    {
        if (rule.access == 0)
            continue;
        int pathFd = open(rule.path.c_str(), O_PATH | O_CLOEXEC);
        if (pathFd < 0)
        {
            error = "cannot open \"" + rule.path + "\" for its sandbox rule: " + strerror(errno);
            close(rulesetFd);
            return false;
        }
        PathBeneathAttr beneath = {rule.access, pathFd};
        long added = syscall(__NR_landlock_add_rule, rulesetFd, kRulePathBeneath, &beneath, 0);
        int addError = errno;
        close(pathFd);
        if (added != 0)
        {
            error = "cannot add the sandbox rule for \"" + rule.path + "\": " + strerror(addError);
            close(rulesetFd);
            return false;
        }
    }

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
    {
        error = std::string("cannot set no-new-privileges, which Landlock requires: ") + strerror(errno);
        close(rulesetFd);
        return false;
    }

    long restricted = syscall(__NR_landlock_restrict_self, rulesetFd, allThreads ? kRestrictSelfTsync : 0U);
    if (restricted != 0 && allThreads && errno == EINVAL)
    {
        // This kernel cannot apply the ruleset to all threads; nothing was applied.
        std::string unexpected;
        if (!OnlyAllowedThreadsRunning(allowedThreads, unexpected))
        {
            error = "other threads are running and would stay outside the sandbox: " + unexpected;
            close(rulesetFd);
            return false;
        }
        restricted = syscall(__NR_landlock_restrict_self, rulesetFd, 0U);
    }
    int restrictError = errno;
    close(rulesetFd);
    if (restricted != 0)
    {
        error = std::string("cannot apply the Landlock ruleset: ") + strerror(restrictError);
        return false;
    }
    return true;
}

}  // namespace landlock
}  // namespace sandbox

#endif // __linux__
