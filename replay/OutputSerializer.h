#pragma once

#include "LogStream.h"
#include <string>
#include <vector>
#include <deque>
#include <unordered_map>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <future>
#include <memory>
#include <cstdint>
#include <sys/types.h>

// Serializes stdout/stderr output from concurrent tasks onto a dedicated thread.
// Optionally enforces task-index ordering so output appears in playlist order
// even when tasks complete out of order.
//
// All public methods are thread-safe. Strings are moved — zero copies across
// the thread boundary after the initial std::string construction.

class OutputSerializer
{
public:
    OutputSerializer();
    ~OutputSerializer();

    OutputSerializer(const OutputSerializer&) = delete;
    OutputSerializer& operator=(const OutputSerializer&) = delete;

    static OutputSerializer& shared();

    // actionIndex >= 0 → ordered stdout (held until its turn)
    // actionIndex == -1 → unordered stdout (printed FIFO immediately)
    void scheduleString(std::string str, int64_t actionIndex);
    void scheduleStrings(std::vector<std::string> strings, int64_t actionIndex);

    // stderr — always unordered FIFO
    void scheduleErrorString(std::string str);

    // Register that action actionIndex produces no output (advances ordering counter)
    void scheduleNoOutput(int64_t actionIndex);

    // Block until all pending output has been written; reset ordering state for
    // the next playlist run.
    void flush();

    // Stop the output thread once it has printed everything queued, and start a new
    // one. The Linux sandbox covers only the threads started after it, so replay stops
    // this thread before applying the sandbox and starts it again afterwards; no thread
    // then stays outside (private/linux_phase5a_sandbox_design.md, section 2). Output
    // scheduled in between waits in the queue; flush() must not be called in between.
    void stopThread();
    void startThread();

#if defined(__linux__)
    // The kernel's id of the current output thread.
    pid_t threadId() const { return _threadId; }
#endif

private:
    struct WorkItem {
        int64_t actionIndex = -1;
        bool isError = false;
        bool isFlush = false;
        std::vector<std::string> strings;
        std::shared_ptr<std::promise<void>> flushPromise;
    };

    void enqueue(WorkItem&& item);
    void threadMain(std::promise<void> started);
    void processItem(WorkItem& item);
    static void printStrings(FILE* stream, const std::vector<std::string>& strings);
    void tryPrintPending();
    void drainPendingForFlush();

    std::thread _thread;
#if defined(__linux__)
    pid_t _threadId = 0; // set by the thread before the constructor returns
#endif
    std::mutex _mutex;
    std::condition_variable _cv;
    std::deque<WorkItem> _queue;
    bool _stopping = false;

    // Accessed only from the worker thread:
    std::unordered_map<int64_t, std::vector<std::string>> _pendingOutputs;
    int64_t _lastPrintedActionIndex = -1;
};
