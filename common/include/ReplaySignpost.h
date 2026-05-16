//
//  ReplaySignpost.h
//
//  Performance instrumentation for replay's dependency analysis pipeline.
//  Three modes, selected by preprocessor flags:
//
//    Default (both 0): all macros are no-ops, zero overhead.
//
//    REPLAY_SIGNPOSTS_ENABLED=1 — os_signpost intervals/events visible in
//      Instruments.app (subsystem "com.abracode.replay", category "scheduler").
//      Build with: ./build.sh --signpost
//
//    REPLAY_TIMING_ENABLED=1 — inline mach_absolute_time() accumulators.
//      Call REPLAY_PRINT_TIMINGS() to dump results to stderr. CLI-friendly.
//      Requires C++ (BEGIN/END are no-ops in .m ObjC-only files).
//      Build with: ./build.sh --timing
//

#pragma once

#ifndef REPLAY_SIGNPOSTS_ENABLED
#define REPLAY_SIGNPOSTS_ENABLED 0
#endif

#ifndef REPLAY_TIMING_ENABLED
#define REPLAY_TIMING_ENABLED 0
#endif

// ─── Mode 1: os_signpost ─────────────────────────────────────────────────────

#if REPLAY_SIGNPOSTS_ENABLED

#include <os/signpost.h>

// Each call site gets its own block-scoped static os_log_t, initialised on
// first use. Pure C (no ObjC blocks) so the macros compile in .c, .m, .cpp,
// and .mm alike.

#define REPLAY_SIGNPOST_BEGIN(name, ...)                                        \
    do {                                                                        \
        static os_log_t _sp_log = NULL;                                         \
        if (_sp_log == NULL)                                                    \
            _sp_log = os_log_create("com.abracode.replay", "scheduler");        \
        os_signpost_interval_begin(_sp_log, OS_SIGNPOST_ID_EXCLUSIVE,           \
                                   name, ##__VA_ARGS__);                        \
    } while(0)

#define REPLAY_SIGNPOST_END(name)                                               \
    do {                                                                        \
        static os_log_t _sp_log = NULL;                                         \
        if (_sp_log == NULL)                                                    \
            _sp_log = os_log_create("com.abracode.replay", "scheduler");        \
        os_signpost_interval_end(_sp_log, OS_SIGNPOST_ID_EXCLUSIVE, name);      \
    } while(0)

#define REPLAY_SIGNPOST_EVENT(name, ...)                                        \
    do {                                                                        \
        static os_log_t _sp_log = NULL;                                         \
        if (_sp_log == NULL)                                                    \
            _sp_log = os_log_create("com.abracode.replay", "scheduler");        \
        os_signpost_event_emit(_sp_log, OS_SIGNPOST_ID_EXCLUSIVE,               \
                               name, ##__VA_ARGS__);                            \
    } while(0)

#define REPLAY_PRINT_TIMINGS()  do {} while(0)

// ─── Mode 2: inline timing accumulators ──────────────────────────────────────

#elif REPLAY_TIMING_ENABLED

// Why mach_absolute_time() rather than gettimeofday():
//   gettimeofday() reads the system wall-clock (µs resolution) and is subject
//   to NTP slew, adjtime() corrections, and manual clock changes — it can go
//   backwards mid-measurement. mach_absolute_time() reads a hardware monotonic
//   counter via a vDSO mapping (no syscall), never goes backwards, and on
//   Apple Silicon the timebase is exactly 1 tick = 1 ns so conversion is
//   trivial. For measuring elapsed intervals it is unambiguously preferable.

// REPLAY_SIGNPOST_EVENT marks a point in time with no duration, so it has no
// meaningful accumulation semantics and is a no-op in timing mode.
#define REPLAY_SIGNPOST_EVENT(name, ...) do {} while(0)

#include <mach/mach_time.h>
#include <cstdio>
#include <cstdint>

// Fixed-capacity array keeps entries in registration (== first-call) order,
// which matches execution order for sequential pipeline stages.
#define REPLAY_TIMING_MAX_ENTRIES 64

struct ReplayTimingEntry {
    const char *name;
    uint64_t    total_ticks;
    uint64_t    count;
};

inline ReplayTimingEntry *_replay_timing_entries[REPLAY_TIMING_MAX_ENTRIES];
inline int _replay_timing_count = 0;

inline void _replay_timing_register(ReplayTimingEntry *e)
{
    if (_replay_timing_count < REPLAY_TIMING_MAX_ENTRIES)
        _replay_timing_entries[_replay_timing_count++] = e;
}

// Thread safety: the accumulator fields (total_ticks, count) are plain
// uint64_t, not atomics. This is intentional: all instrumented intervals are
// sequential pipeline stages that run on the calling thread (main thread).
// GCD worker threads inside SchedulerExecution never touch these variables —
// only the BEGIN/END that wraps the scheduler call does. Using std::atomic
// would add unnecessary barriers for no benefit. If a future BEGIN/END is
// placed inside a concurrent block, atomics or a mutex would be required.
//
// REPLAY_SIGNPOST_BEGIN declares _sp_begin_ticks in the enclosing scope;
// REPLAY_SIGNPOST_END references it. Both macros must appear as paired
// statements at the same brace level — the same contract as os_signpost.

#define REPLAY_SIGNPOST_BEGIN(name, ...)                                        \
    uint64_t _sp_begin_ticks = mach_absolute_time()

#define REPLAY_SIGNPOST_END(name)                                               \
    do {                                                                        \
        static ReplayTimingEntry _sp_entry = {name, 0, 0};                     \
        static bool _sp_registered = false;                                     \
        _sp_entry.total_ticks += mach_absolute_time() - _sp_begin_ticks;       \
        _sp_entry.count++;                                                      \
        if (!_sp_registered) {                                                  \
            _replay_timing_register(&_sp_entry);                                \
            _sp_registered = true;                                              \
        }                                                                       \
    } while(0)

#define REPLAY_PRINT_TIMINGS()                                                  \
    do {                                                                        \
        mach_timebase_info_data_t _tb = {0, 0};                                \
        mach_timebase_info(&_tb);                                               \
        double _scale = (double)_tb.numer / (double)_tb.denom / 1e6;           \
        fprintf(stderr, "\n[timing] %-38s  %9s  %s\n",                         \
                "interval", "ms", "calls");                                     \
        for (int _i = 0; _i < _replay_timing_count; _i++) {                    \
            ReplayTimingEntry *_e = _replay_timing_entries[_i];                 \
            fprintf(stderr, "[timing] %-38s  %9.3f  %llu\n",                   \
                    _e->name,                                                   \
                    (double)_e->total_ticks * _scale,                           \
                    (unsigned long long)_e->count);                             \
        }                                                                       \
        fprintf(stderr, "\n");                                                  \
    } while(0)

// ─── Default: all no-ops ─────────────────────────────────────────────────────

#else

#define REPLAY_SIGNPOST_BEGIN(name, ...) do {} while(0)
#define REPLAY_SIGNPOST_END(name)        do {} while(0)
#define REPLAY_SIGNPOST_EVENT(name, ...) do {} while(0)
#define REPLAY_PRINT_TIMINGS()           do {} while(0)

#endif  // REPLAY_SIGNPOSTS_ENABLED / REPLAY_TIMING_ENABLED
