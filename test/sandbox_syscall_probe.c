// Run inside the sandbox by test_sandbox_linux.sh: makes the system calls the sandbox's
// filter denies, and allowed neighbors of each as controls, and prints one
// "<name> <errno name>" line per call ("ok" for success).
//
// Usage: sandbox_syscall_probe <file the sandbox may write>

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <sys/xattr.h>
#include <unistd.h>

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
        default: return strerror(err);
    }
}

static void report(const char *what, long result)
{
    printf("%s %s\n", what, name_of(result < 0 ? errno : 0));
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
    return 0;
}
