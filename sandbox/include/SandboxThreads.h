//
//  SandboxThreads.h
//
//  The thread check of the Linux sandbox. Landlock restricts only the thread that
//  applies it and the threads that thread creates afterwards; a thread that already
//  runs stays unrestricted, and so does everything it starts later. Before applying
//  Landlock, the sandbox therefore makes sure no other thread runs except those the
//  caller knows to be harmless (private/linux_phase5a_sandbox_design.md, section 2).
//

#pragma once

#include <string>
#include <vector>
#include <sys/types.h>

namespace sandbox
{

// True when every thread of the process other than the calling one is in `allowed`
// (kernel thread ids). Otherwise false, with `unexpected` naming each other thread as
// "<id> (<name>)", or saying why the threads could not be listed: a check that cannot
// list them fails, so the sandbox fails closed.
//
// On platforms whose sandbox covers the whole process (macOS), the check is not needed
// and always returns true.
bool OnlyAllowedThreadsRunning(const std::vector<pid_t>& allowed, std::string& unexpected);

}  // namespace sandbox
