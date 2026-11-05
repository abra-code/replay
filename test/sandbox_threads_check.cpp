// Checks sandbox::OnlyAllowedThreadsRunning (sandbox/SandboxThreads.cpp): it passes with
// no other thread, fails and names a thread it was not told about, and passes again once
// that thread is allowed. On macOS it must always pass (the sandbox covers the process).
// Built and run by test_sandbox_threads.sh.

#include "SandboxThreads.h"

#include <pthread.h>
#include <stdio.h>
#include <condition_variable>
#include <mutex>
#include <thread>
#if defined(__linux__)
#include <sys/syscall.h>
#include <unistd.h>
#endif

static int s_pass = 0;
static int s_fail = 0;

static void check(bool condition, const char *what, const std::string &detail)
{
    if (condition)
    {
        s_pass++;
        printf("  PASS: %s\n", what);
        return;
    }
    s_fail++;
    printf("  FAIL: %s (%s)\n", what, detail.c_str());
}

int main()
{
    std::string unexpected;
    bool ok = sandbox::OnlyAllowedThreadsRunning({}, unexpected);
    check(ok && unexpected.empty(), "a single thread passes", unexpected);

    // A second thread that names itself and waits until it is told to finish.
    std::mutex mutex;
    std::condition_variable cv;
    bool ready = false;
    bool finish = false;
    pid_t probeId = 0;
    std::thread probe([&] {
#if defined(__APPLE__)
        pthread_setname_np("probe-thread");
#else
        pthread_setname_np(pthread_self(), "probe-thread");
#endif
        std::unique_lock<std::mutex> lock(mutex);
#if defined(__linux__)
        probeId = (pid_t)syscall(SYS_gettid);
#endif
        ready = true;
        cv.notify_all();
        cv.wait(lock, [&] { return finish; });
    });
    {
        std::unique_lock<std::mutex> lock(mutex);
        cv.wait(lock, [&] { return ready; });
    }

    ok = sandbox::OnlyAllowedThreadsRunning({}, unexpected);
#if defined(__linux__)
    check(!ok, "an unexpected thread fails the check", unexpected);
    std::string expected = std::to_string(probeId) + " (probe-thread)";
    check(unexpected == expected, "the failure names the thread by id and name", unexpected);
    ok = sandbox::OnlyAllowedThreadsRunning({probeId}, unexpected);
    check(ok && unexpected.empty(), "the same thread passes once allowed", unexpected);
    ok = sandbox::OnlyAllowedThreadsRunning({probeId + 100000}, unexpected);
    check(!ok, "allowing another id does not let it through", unexpected);
#else
    (void)probeId; // set only on Linux
    check(ok && unexpected.empty(), "without a per-thread sandbox the check always passes", unexpected);
#endif

    {
        std::lock_guard<std::mutex> lock(mutex);
        finish = true;
    }
    cv.notify_all();
    probe.join();

    printf("Passed: %d  Failed: %d\n", s_pass, s_fail);
    return s_fail == 0 ? 0 : 1;
}
