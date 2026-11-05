//
//  SandboxSeccomp.cpp
//
//  See SandboxSeccomp.h. Linux only; empty elsewhere.
//

#if defined(__linux__)

#include "SandboxSeccomp.h"

#include <errno.h>
#include <stddef.h>
#include <string.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cstdint>
#include <utility>
#include <vector>

// The arch checks name the little-endian ABIs, and the ioctl request is read as the low
// word of args[1], which sits first only on a little-endian machine.
static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "the system call filter assumes a little-endian machine");

namespace sandbox
{
namespace seccomp
{

namespace
{

// Added in Linux 6.13; the same number on every architecture this builds for, and on
// their 32-bit compat entries. Older kernels answer ENOSYS, so denying them is harmless.
constexpr uint32_t kSetxattrat = 463;
constexpr uint32_t kRemovexattrat = 466;
constexpr uint32_t kIoUringSetup = 425;
constexpr uint32_t kIoUringEnter = 426;
constexpr uint32_t kIoUringRegister = 427;

// The 32-bit compat entry of each 64-bit architecture: i386 on x86_64, 32-bit Arm on
// aarch64. Its system call numbers differ from the native ones; for these calls they
// are the same on both (i386 and Arm EABI).
constexpr uint32_t kCompatSetxattr = 226, kCompatLsetxattr = 227, kCompatFsetxattr = 228;
constexpr uint32_t kCompatRemovexattr = 235, kCompatLremovexattr = 236, kCompatFremovexattr = 237;
constexpr uint32_t kCompatIoctl = 54;

#if defined(__x86_64__)
constexpr uint32_t kNativeArch = AUDIT_ARCH_X86_64;
constexpr uint32_t kCompatArch = AUDIT_ARCH_I386;
constexpr bool kHasX32 = true; // x32 calls arrive with the native arch and bit 30 set
#elif defined(__aarch64__)
constexpr uint32_t kNativeArch = AUDIT_ARCH_AARCH64;
constexpr uint32_t kCompatArch = AUDIT_ARCH_ARM;
constexpr bool kHasX32 = false;
#else
#error The sandbox's system call filter supports x86_64 and aarch64 only
#endif

constexpr uint32_t kX32Bit = 0x40000000U;

constexpr uint32_t Errno(int err)
{
    return SECCOMP_RET_ERRNO | ((uint32_t)err & SECCOMP_RET_DATA);
}

constexpr uint32_t kOffsetNr = offsetof(struct seccomp_data, nr);
constexpr uint32_t kOffsetArch = offsetof(struct seccomp_data, arch);
// The ioctl request is the second argument. The kernel takes it as an unsigned int,
// so only its low 32 bits count, which on these little-endian architectures come first.
constexpr uint32_t kOffsetArg1Low = offsetof(struct seccomp_data, args) + sizeof(uint64_t);

// The checks for one architecture entry, with the system call number in the
// accumulator: each listed number returns its answer, ioctl looks at its request, and
// everything else is allowed.
std::vector<sock_filter> Section(const std::vector<std::pair<uint32_t, uint32_t>>& denied,
                                 uint32_t ioctlNr, bool x32)
{
    std::vector<sock_filter> code;
    code.push_back(BPF_STMT(BPF_LD | BPF_W | BPF_ABS, kOffsetNr));
    if (x32)
    {
        code.push_back(BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, kX32Bit, 0, 1));
        code.push_back(BPF_STMT(BPF_RET | BPF_K, Errno(ENOSYS)));
    }
    for (const auto& entry : denied)
    {
        code.push_back(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, entry.first, 0, 1));
        code.push_back(BPF_STMT(BPF_RET | BPF_K, entry.second));
    }
    // ioctl: deny TIOCSTI and TIOCLINUX, allow every other request. Jump offsets count
    // from the next instruction.
    code.push_back(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, ioctlNr, 0, 5));     // not ioctl: to the last ALLOW
    code.push_back(BPF_STMT(BPF_LD | BPF_W | BPF_ABS, kOffsetArg1Low));
    code.push_back(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, TIOCSTI, 2, 0));     // to the EACCES
    code.push_back(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, TIOCLINUX, 1, 0));   // to the EACCES
    code.push_back(BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW));
    code.push_back(BPF_STMT(BPF_RET | BPF_K, Errno(EACCES)));
    code.push_back(BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW));
    return code;
}

std::vector<sock_filter> BuildProgram()
{
    const uint32_t deny = Errno(EACCES);
    const uint32_t missing = Errno(ENOSYS);

    std::vector<sock_filter> native = Section({
        {__NR_setxattr, deny}, {__NR_lsetxattr, deny}, {__NR_fsetxattr, deny},
        {__NR_removexattr, deny}, {__NR_lremovexattr, deny}, {__NR_fremovexattr, deny},
        {kSetxattrat, deny}, {kRemovexattrat, deny},
        {kIoUringSetup, missing}, {kIoUringEnter, missing}, {kIoUringRegister, missing},
    }, __NR_ioctl, kHasX32);

    std::vector<sock_filter> compat = Section({
        {kCompatSetxattr, deny}, {kCompatLsetxattr, deny}, {kCompatFsetxattr, deny},
        {kCompatRemovexattr, deny}, {kCompatLremovexattr, deny}, {kCompatFremovexattr, deny},
        {kSetxattrat, deny}, {kRemovexattrat, deny},
        {kIoUringSetup, missing}, {kIoUringEnter, missing}, {kIoUringRegister, missing},
    }, kCompatIoctl, false);

    // arch == native: the native section; arch == compat: the compat section; any
    // other architecture cannot occur, and is killed rather than allowed.
    std::vector<sock_filter> program;
    program.push_back(BPF_STMT(BPF_LD | BPF_W | BPF_ABS, kOffsetArch));
    program.push_back(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, kNativeArch, 0, (uint8_t)native.size()));
    program.insert(program.end(), native.begin(), native.end());
    program.push_back(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, kCompatArch, 0, (uint8_t)compat.size()));
    program.insert(program.end(), compat.begin(), compat.end());
    program.push_back(BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS));
    return program;
}

static_assert(sizeof(sock_filter) == 8, "unexpected sock_filter layout");

}  // namespace


bool ApplyFilter(std::string& error)
{
    std::vector<sock_filter> program = BuildProgram();
    // Each jump over a section must fit the 8-bit offset; the sections are a few dozen
    // instructions.
    if (program.size() > 250)
    {
        error = "the system call filter is too long";
        return false;
    }
    struct sock_fprog fprog = {(unsigned short)program.size(), program.data()};

    // TSYNC: every thread gets the filter; a thread that cannot take it makes the call
    // fail (it returns that thread's id), and nothing is installed.
    long result = syscall(__NR_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, &fprog);
    if (result != 0)
    {
        if (result > 0)
            error = "cannot install the system call filter on thread " + std::to_string(result);
        else
            error = std::string("cannot install the system call filter: ") + strerror(errno);
        return false;
    }
    return true;
}

}  // namespace seccomp
}  // namespace sandbox

#endif // __linux__
