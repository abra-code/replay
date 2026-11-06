// Built and run by test_sandbox_linux.sh: installs the sandbox's system call filter
// (sandbox/SandboxSeccomp.cpp) with the options given, without Landlock, then replaces
// itself with the program named after "--". execv starts no new process, so this works
// with process creation denied, and the program runs under the filter.
//
// Usage: sandbox_filter_exec [--deny-network] [--deny-unix-sockets] [--deny-fork] -- program [args...]

#include "../sandbox/SandboxSeccomp.h"

#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

#include <string>

int main(int argc, char **argv)
{
    sandbox::seccomp::FilterOptions options;
    int i = 1;
    for (; i < argc; i++)
    {
        if (strcmp(argv[i], "--deny-network") == 0)
            options.denyNetwork = true;
        else if (strcmp(argv[i], "--deny-unix-sockets") == 0)
            options.denyUnixSockets = true;
        else if (strcmp(argv[i], "--deny-fork") == 0)
            options.denyFork = true;
        else if (strcmp(argv[i], "--") == 0)
            break;
        else
        {
            fprintf(stderr, "error: unknown option %s\n", argv[i]);
            return 2;
        }
    }
    if ((i + 1) >= argc)
    {
        fprintf(stderr, "usage: %s [--deny-network] [--deny-unix-sockets] [--deny-fork] -- program [args...]\n", argv[0]);
        return 2;
    }

    // The filter needs no-new-privileges, which the Landlock step sets in the tools.
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
    {
        perror("prctl(PR_SET_NO_NEW_PRIVS)");
        return 1;
    }
    std::string error;
    if (!sandbox::seccomp::ApplyFilter(options, error))
    {
        fprintf(stderr, "error: %s\n", error.c_str());
        return 1;
    }
    execv(argv[i + 1], &argv[i + 1]);
    perror("execv");
    return 1;
}
