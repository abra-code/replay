//
//  SandboxSeccomp.h
//
//  The Linux sandbox's system call filter (seccomp), installed after Landlock on every
//  thread. It covers what Landlock does not and the cache relies on
//  (private/linux_phase5a_sandbox_design.md, section 6):
//    - extended attribute writes and removals are denied everywhere (EACCES), so a
//      sandboxed command cannot forge a fingerprint memo on a file it cannot write;
//    - io_uring is unavailable (ENOSYS): its own SETXATTR operations bypass any
//      system call filter, and programs fall back to ordinary calls;
//    - the terminal ioctls TIOCSTI and TIOCLINUX are denied (EACCES): they push
//      characters into a terminal's input, which would let a child type into the
//      user's shell.
//  Internal to the sandbox module; Linux only.
//

#pragma once

#if defined(__linux__)

#include <string>

namespace sandbox
{
namespace seccomp
{

// Installs the filter on all threads of the process. The process must already have
// no-new-privileges set (the Landlock step sets it). False with `error` on failure;
// the caller must not continue.
bool ApplyFilter(std::string& error);

}  // namespace seccomp
}  // namespace sandbox

#endif // __linux__
