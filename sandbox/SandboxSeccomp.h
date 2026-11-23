//
//  SandboxSeccomp.h
//
//  The Linux sandbox's system call filter (seccomp), installed after Landlock on every
//  thread. It covers what Landlock does not and the cache relies on:
//    - extended attribute writes and removals are denied everywhere (EACCES), so a
//      sandboxed command cannot forge a fingerprint memo on a file it cannot write;
//    - io_uring is unavailable (ENOSYS): its own SETXATTR operations bypass any
//      system call filter, and programs fall back to ordinary calls;
//    - the terminal ioctls TIOCSTI and TIOCLINUX are denied (EACCES): they push
//      characters into a terminal's input, which would let a child type into the
//      user's shell;
//    - when asked, creating Unix sockets is denied (EACCES): for the MCP server on a
//      kernel below Landlock ABI 9, which cannot limit connecting to them (section 9),
//      and with the network denied, on every ABI;
//    - when the network is denied, creating a socket of any other family is denied
//      (EACCES): IPv4, IPv6, netlink, packet, vsock and the rest (Phase 5b);
//    - when process creation is denied, clone without CLONE_THREAD, fork and vfork are
//      denied (EACCES) and clone3 is unavailable (ENOSYS, so glibc falls back to clone
//      for its threads). This also denies posix_spawn: no program can be started.
//  Internal to the sandbox module; Linux only.
//

#pragma once

#if defined(__linux__)

#include <string>

namespace sandbox
{
namespace seccomp
{

struct FilterOptions
{
    bool denyUnixSockets = false; // socket(AF_UNIX) is denied
    bool denyNetwork = false;     // socket() of every other family is denied
    bool denyFork = false;        // new processes are denied, threads stay allowed
};

// Installs the filter on all threads of the process. The process must already have
// no-new-privileges set (the Landlock step sets it). False with `error` on failure;
// the caller must not continue.
bool ApplyFilter(const FilterOptions& options, std::string& error);

}  // namespace seccomp
}  // namespace sandbox

#endif // __linux__
