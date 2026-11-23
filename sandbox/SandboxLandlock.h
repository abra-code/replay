//
//  SandboxLandlock.h
//
//  The Linux sandbox: Landlock rules built from sandbox::Config. Internal to the
//  sandbox module; SandboxProfile.cpp calls it on Linux.
//

#pragma once

#if defined(__linux__)

#include "SandboxProfile.h"

#include <cstdint>
#include <string>
#include <vector>
#include <sys/types.h>

namespace sandbox
{
namespace landlock
{

// Landlock file system rights (include/uapi/linux/landlock.h). Defined here because
// the headers of the build image lag behind the kernels the tool runs on.
constexpr uint64_t kExecute     = 1ULL << 0;
constexpr uint64_t kWriteFile   = 1ULL << 1;
constexpr uint64_t kReadFile    = 1ULL << 2;
constexpr uint64_t kReadDir     = 1ULL << 3;
constexpr uint64_t kRemoveDir   = 1ULL << 4;
constexpr uint64_t kRemoveFile  = 1ULL << 5;
constexpr uint64_t kMakeChar    = 1ULL << 6;
constexpr uint64_t kMakeDir     = 1ULL << 7;
constexpr uint64_t kMakeReg     = 1ULL << 8;
constexpr uint64_t kMakeSock    = 1ULL << 9;
constexpr uint64_t kMakeFifo    = 1ULL << 10;
constexpr uint64_t kMakeBlock   = 1ULL << 11;
constexpr uint64_t kMakeSym     = 1ULL << 12;
constexpr uint64_t kRefer       = 1ULL << 13; // ABI 2
constexpr uint64_t kTruncate    = 1ULL << 14; // ABI 3
constexpr uint64_t kIoctlDev    = 1ULL << 15; // ABI 5, never handled
constexpr uint64_t kResolveUnix = 1ULL << 16; // ABI 9

constexpr uint64_t kScopeAbstractUnix = 1ULL << 0; // ABI 6
constexpr uint64_t kScopeSignal = 1ULL << 1;  // ABI 6

// The lowest ABI the sandbox accepts: cross-folder rename (2) and truncate control (3).
constexpr int kMinimumAbi = 3;

// The kernel's Landlock ABI, or -1 with the errno in *error.
int Abi(int *error);

struct Rule
{
    std::string path;   // canonical
    uint64_t access;    // rights granted beneath path (or on the file itself)
    bool isDirectory;
    std::string why;    // "granted", "baseline", "allow_exec", ...
};

struct RuleSet
{
    int abi = 0;
    uint64_t handledAccess = 0; // every right this ruleset denies unless a rule grants it
    uint64_t scoped = 0;
    std::vector<Rule> rules;
    std::vector<std::string> warnings; // to print on stderr
};

// The rules for `config` at `abi`. False with `error` when a path must be refused
// (a missing read path; a missing write path whose nearest existing folder is too
// broad to grant in its place).
bool BuildRules(const Config& config, int abi, RuleSet& out, std::string& error);

// A human-readable listing for --verbose.
std::string Describe(const RuleSet& ruleset);

// Restricts the process. Below ABI 8 (or if the kernel refuses to apply the ruleset
// to all threads) every thread other than the caller must be in `allowedThreads`.
// False with `error` if anything fails; the caller must not continue.
bool Apply(const RuleSet& ruleset, const std::vector<pid_t>& allowedThreads, std::string& error);

}  // namespace landlock
}  // namespace sandbox

#endif // __linux__
