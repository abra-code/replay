//
//  OutputSerializer.mm
//  replay
//
//  OutputSerializer serializes stdout/stderr writes from concurrent tasks onto
//  a dedicated std::thread, avoiding interleaving and optionally enforcing
//  task-index ordering even when tasks complete out of order.
//
//  A dedicated long-lived thread is used rather than a GCD serial queue to
//  avoid consuming slots from the shared GCD thread pool (capped at 64 on
//  macOS), which would compete with the task workers.

#include "OutputSerializer.h"
#include <cassert>
#include <cstdio>

// ---------------------------------------------------------------------------
// Singleton
// ---------------------------------------------------------------------------

OutputSerializer& OutputSerializer::shared()
{
    static OutputSerializer sShared;
    return sShared;
}

// ---------------------------------------------------------------------------
// Construction / destruction
// ---------------------------------------------------------------------------

OutputSerializer::OutputSerializer()
{
    _thread = std::thread(&OutputSerializer::threadMain, this);
}

OutputSerializer::~OutputSerializer()
{
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _stopping = true;
        _cv.notify_one();
    }
    if (_thread.joinable())
        _thread.join();
}

// ---------------------------------------------------------------------------
// Producer-side scheduling (called from any thread)
// ---------------------------------------------------------------------------

void OutputSerializer::enqueue(WorkItem&& item)
{
    std::lock_guard<std::mutex> lock(_mutex);
    _queue.push_back(std::move(item));
    _cv.notify_one();
}

void OutputSerializer::scheduleString(std::string str, int64_t actionIndex)
{
    WorkItem item;
    item.actionIndex = actionIndex;
    item.strings.push_back(std::move(str));
    enqueue(std::move(item));
}

void OutputSerializer::scheduleStrings(std::vector<std::string> strings, int64_t actionIndex)
{
    WorkItem item;
    item.actionIndex = actionIndex;
    item.strings = std::move(strings);
    enqueue(std::move(item));
}

void OutputSerializer::scheduleErrorString(std::string str)
{
    WorkItem item;
    item.isError = true;
    item.strings.push_back(std::move(str));
    enqueue(std::move(item));
}

void OutputSerializer::scheduleNoOutput(int64_t actionIndex)
{
    WorkItem item;
    item.actionIndex = actionIndex;
    // strings left empty — signals "advance ordering counter, no output"
    enqueue(std::move(item));
}

void OutputSerializer::flush()
{
    auto promise = std::make_shared<std::promise<void>>();
    std::future<void> future = promise->get_future();
    WorkItem item;
    item.isFlush = true;
    item.flushPromise = std::move(promise);
    enqueue(std::move(item));
    future.wait();
}

// ---------------------------------------------------------------------------
// Worker-thread helpers (called only from threadMain)
// ---------------------------------------------------------------------------

/*static*/ void OutputSerializer::printStrings(FILE* stream, const std::vector<std::string>& strings)
{
    for (const auto& s : strings)
        fprintf(stream, "%s", s.c_str());
}

void OutputSerializer::tryPrintPending()
{
    while (true)
    {
        int64_t next = _lastPrintedActionIndex + 1;
        auto it = _pendingOutputs.find(next);
        if (it == _pendingOutputs.end())
            break;
        printStrings(gLogOut, it->second);
        _pendingOutputs.erase(it);
        _lastPrintedActionIndex = next;
    }
}

void OutputSerializer::drainPendingForFlush()
{
    if (_pendingOutputs.empty())
        return;

    fprintf(gLogErr, "Not all task outputs have been printed before \"replay\" finished playlist execution\n");

    while (!_pendingOutputs.empty())
    {
        int64_t next = _lastPrintedActionIndex + 1;
        auto it = _pendingOutputs.find(next);
        if (it != _pendingOutputs.end())
        {
            printStrings(gLogOut, it->second);
            _pendingOutputs.erase(it);
            _lastPrintedActionIndex = next;
        }
        else
        {
            // Gap in sequence — skip to the lowest available index to avoid spinning
            int64_t minIdx = _pendingOutputs.begin()->first;
            for (const auto& kv : _pendingOutputs)
                if (kv.first < minIdx) minIdx = kv.first;
            _lastPrintedActionIndex = minIdx - 1;
        }
    }

    assert(!"all task outputs should be delivered before flush");
}

void OutputSerializer::processItem(WorkItem& item)
{
    if (item.isFlush)
    {
        drainPendingForFlush();
        _lastPrintedActionIndex = -1;
        if (item.flushPromise != nullptr)
            item.flushPromise->set_value();
        return;
    }

    if (item.isError)
    {
        printStrings(gLogErr, item.strings);
        return;
    }

    int64_t actionIndex = item.actionIndex;

    if (actionIndex < 0)
    {
        // Unordered: print immediately in FIFO order
        printStrings(gLogOut, item.strings);
        return;
    }

    // Ordered path
    if (actionIndex == _lastPrintedActionIndex + 1)
    {
        // In sequence — print and flush any pending items that are now unblocked
        printStrings(gLogOut, item.strings);
        _lastPrintedActionIndex = actionIndex;
        tryPrintPending();
    }
    else if (actionIndex <= _lastPrintedActionIndex)
    {
        // Contract violation: action index already processed
        printStrings(gLogOut, item.strings);
        assert(actionIndex > _lastPrintedActionIndex);
    }
    else
    {
        // Out of order — hold until preceding items arrive
        _pendingOutputs[actionIndex] = std::move(item.strings);
    }
}

// ---------------------------------------------------------------------------
// Worker thread entry point
// ---------------------------------------------------------------------------

void OutputSerializer::threadMain()
{
    std::unique_lock<std::mutex> lock(_mutex);
    while (true)
    {
        _cv.wait(lock, [this]{ return !_queue.empty() || _stopping; });
        if (_stopping && _queue.empty())
            break;

        WorkItem item = std::move(_queue.front());
        _queue.pop_front();
        lock.unlock();

        processItem(item);

        lock.lock();
    }
}
