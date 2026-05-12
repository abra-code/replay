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

private:
    struct WorkItem {
        int64_t actionIndex = -1;
        bool isError = false;
        bool isFlush = false;
        std::vector<std::string> strings;
        std::shared_ptr<std::promise<void>> flushPromise;
    };

    void enqueue(WorkItem&& item);
    void threadMain();
    void processItem(WorkItem& item);
    static void printStrings(FILE* stream, const std::vector<std::string>& strings);
    void tryPrintPending();
    void drainPendingForFlush();

    std::thread _thread;
    std::mutex _mutex;
    std::condition_variable _cv;
    std::deque<WorkItem> _queue;
    bool _stopping = false;

    // Accessed only from the worker thread:
    std::unordered_map<int64_t, std::vector<std::string>> _pendingOutputs;
    int64_t _lastPrintedActionIndex = -1;
};
