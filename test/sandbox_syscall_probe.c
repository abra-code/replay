// Run inside the sandbox by test_sandbox_linux.sh: makes the system calls the sandbox's
// filter denies, and allowed neighbors of each as controls, and prints one
// "<name> <errno name>" line per call ("ok" for success).
//
// Usage: sandbox_syscall_probe <file the sandbox may write>

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/wait.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/xattr.h>
#include <unistd.h>

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif

extern char **environ;

static const char *name_of(int err)
{
    switch (err)
    {
        case 0: return "ok";
        case EACCES: return "EACCES";
        case EPERM: return "EPERM";
        case ENOSYS: return "ENOSYS";
        case ENOTTY: return "ENOTTY";
        case ENODATA: return "ENODATA";
        case ENOTSUP: return "ENOTSUP";
        case EBADF: return "EBADF";
        case EFAULT: return "EFAULT";
        case EINVAL: return "EINVAL";
        case EAFNOSUPPORT: return "EAFNOSUPPORT";
        default: return strerror(err);
    }
}

static void report(const char *what, long result)
{
    printf("%s %s\n", what, name_of(result < 0 ? errno : 0));
}

static void *thread_body(void *arg)
{
    return arg;
}

int main(int argc, char **argv)
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <writable file>\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];

    errno = 0;
    report("setxattr", setxattr(path, "user.replay.probe", "x", 1, 0));
    errno = 0;
    report("lsetxattr", lsetxattr(path, "user.replay.probe", "x", 1, 0));
    errno = 0;
    report("removexattr", removexattr(path, "user.replay.probe"));
    errno = 0;
    report("lremovexattr", lremovexattr(path, "user.replay.probe"));
    int fd = open(path, O_RDWR);
    errno = 0;
    report("fsetxattr", fsetxattr(fd, "user.replay.probe", "x", 1, 0));
    errno = 0;
    report("fremovexattr", fremovexattr(fd, "user.replay.probe"));
    if (fd >= 0)
        close(fd);
    // setxattrat and removexattrat (Linux 6.13) by number, since older headers lack them.
    // A kernel without them answers ENOSYS; only the filter answers EACCES. The
    // arguments are invalid on purpose: a kernel that has them rejects them (EFAULT or
    // EINVAL) before doing anything.
    errno = 0;
    report("setxattrat", syscall(463, -1, NULL, 0, NULL, NULL, 0));
    errno = 0;
    report("removexattrat", syscall(466, -1, NULL, 0, NULL));
    char value[8];
    errno = 0;
    report("getxattr", getxattr(path, "user.replay.probe", value, sizeof(value))); // control: allowed

    // io_uring_setup(entries, params): with a null params pointer an unfiltered kernel
    // answers EFAULT; the filter answers ENOSYS before the kernel looks.
    errno = 0;
    report("io_uring_setup", syscall(425, 1, NULL));

    // On stdin, which is not a terminal here: an unfiltered kernel answers ENOTTY.
    char c = 'x';
    errno = 0;
    report("TIOCSTI", ioctl(0, TIOCSTI, &c));
    struct winsize ws;
    errno = 0;
    report("TIOCGWINSZ", ioctl(0, TIOCGWINSZ, &ws)); // control: allowed, ENOTTY

    // Unix sockets: denied in MCP server mode on kernels below Landlock ABI 9 and with the
    // network denied, allowed otherwise. socketpair is always allowed; other address
    // families are allowed unless the network is denied.
    errno = 0;
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    report("socket-unix", s);
    if (s >= 0)
        close(s);
    int pair[2];
    errno = 0;
    int pairResult = socketpair(AF_UNIX, SOCK_STREAM, 0, pair);
    report("socketpair-unix", pairResult);
    if (pairResult == 0)
    {
        close(pair[0]);
        close(pair[1]);
    }
    errno = 0;
    s = socket(AF_INET, SOCK_DGRAM, 0);
    report("socket-inet", s);
    if (s >= 0)
        close(s);

    // The other families a denied network also denies. An unfiltered kernel may refuse
    // some on its own (packet needs CAP_NET_RAW: EPERM; vsock without a hypervisor:
    // EAFNOSUPPORT); only the filter answers EACCES.
    static const struct { const char *name; int family; int type; } kFamilies[] = {
        {"socket-inet6", AF_INET6, SOCK_DGRAM},
        {"socket-netlink", AF_NETLINK, SOCK_RAW},
        {"socket-packet", AF_PACKET, SOCK_DGRAM},
        {"socket-vsock", AF_VSOCK, SOCK_STREAM},
    };
    for (size_t i = 0; i < sizeof(kFamilies) / sizeof(kFamilies[0]); i++)
    {
        errno = 0;
        s = socket(kFamilies[i].family, kFamilies[i].type, 0);
        report(kFamilies[i].name, s);
        if (s >= 0)
            close(s);
    }

    // Process creation: denied with "allow_fork": false, threads stay allowed.
    pthread_t thread;
    int threadResult = pthread_create(&thread, NULL, thread_body, NULL);
    errno = threadResult;
    report("thread", threadResult == 0 ? 0 : -1);
    if (threadResult == 0)
        pthread_join(thread, NULL);

    errno = 0;
    pid_t child = fork();
    if (child == 0)
        _exit(0);
    report("fork", child);
    if (child > 0)
        waitpid(child, NULL, 0);

    char *spawnArgv[] = {"/bin/true", NULL};
    pid_t spawned = 0;
    int spawnResult = posix_spawn(&spawned, "/bin/true", NULL, NULL, spawnArgv, environ);
    errno = spawnResult;
    report("posix_spawn", spawnResult == 0 ? 0 : -1);
    if (spawnResult == 0)
        waitpid(spawned, NULL, 0);

#ifdef SYS_fork
    // x86_64 has a fork system call of its own, which glibc's fork() does not use (it
    // calls clone); aarch64 has none.
    errno = 0;
    long rawForked = syscall(SYS_fork);
    if (rawForked == 0)
        _exit(0);
    report("fork-syscall", rawForked);
    if (rawForked > 0)
        waitpid((pid_t)rawForked, NULL, 0);
#endif

    errno = 0;
    pid_t vforked = vfork();
    if (vforked == 0)
        _exit(0);
    report("vfork", vforked);
    if (vforked > 0)
        waitpid(vforked, NULL, 0);

    // clone3(args, size) with a null args pointer: an unfiltered kernel answers EFAULT or
    // EINVAL; the filter answers ENOSYS before the kernel looks.
    errno = 0;
    report("clone3", syscall(435, NULL, 0));
    return 0;
}
