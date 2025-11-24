//
//  dispatch_queues_helper.cpp
//  fingerprint
//
//  Created by Tomasz Kukielka on 10/9/25.
//

#include "dispatch_queues_helper.h"

#include <unistd.h>
#include <sys/sysctl.h>

static dispatch_group_t s_all_tasks_group = nullptr;
static dispatch_once_t s_all_tasks_token;

dispatch_group_t get_all_tasks_group() noexcept
{
    dispatch_once(&s_all_tasks_token, ^{
        s_all_tasks_group = dispatch_group_create();
    });
    return s_all_tasks_group;
}

static int get_physical_core_count()
{
    // POSIX: online logical cores (fastest, works everywhere)
    long online = sysconf(_SC_NPROCESSORS_ONLN);
    if (online > 0)
        return static_cast<int>(online);

    // Fallback: sysctlbyname for hw.physicalcpu (Apple Silicon accurate)
    int cores = 0;
    size_t len = sizeof(cores);
    if (sysctlbyname("hw.physicalcpu", &cores, &len, nullptr, 0) == 0 && cores > 0)
        return cores;

    // Final fallback: logical via sysctlbyname
    if (sysctlbyname("hw.logicalcpu", &cores, &len, nullptr, 0) == 0 && cores > 0)
        return cores;

    return 8; // sane default
}

dispatch_queue_t get_cpu_gate_queue() noexcept
{
    static dispatch_once_t once;
    static dispatch_queue_t queue;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("serial.cpu.gate", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

dispatch_semaphore_t get_concurrency_semaphore() noexcept
{
    static dispatch_once_t once;
    static dispatch_semaphore_t cpu_count_semaphopre;
    dispatch_once(&once, ^{
        int cores = get_physical_core_count();           // e.g. 8 on M2, 10 on M3 Pro
        cpu_count_semaphopre = dispatch_semaphore_create(cores);         // 1:1 with NEON units
    });
    return cpu_count_semaphopre;
}


static dispatch_queue_t s_concurrent_file_processing_queue = nullptr;
static dispatch_once_t s_concurrent_file_processing_once_token;

dispatch_queue_t get_file_processing_queue() noexcept
{
    dispatch_once(&s_concurrent_file_processing_once_token, ^{
        s_concurrent_file_processing_queue = dispatch_queue_create("concurrent.file.processing", DISPATCH_QUEUE_CONCURRENT);
    });
    
    return s_concurrent_file_processing_queue;
}

static dispatch_queue_t s_directory_traversal_queue = nullptr;
static dispatch_once_t s_directory_traversal_once_token;

dispatch_queue_t get_directory_traversal_queue() noexcept
{
    dispatch_once(&s_directory_traversal_once_token, ^{
        s_directory_traversal_queue = dispatch_queue_create("concurrent.dir.traversal", DISPATCH_QUEUE_CONCURRENT);
    });
    
    return s_directory_traversal_queue;
}

static dispatch_queue_t s_shared_container_mutation_queue = nullptr;
static dispatch_once_t s_shared_container_mutation_once_token;

dispatch_queue_t get_shared_container_mutation_queue() noexcept
{
    dispatch_once(&s_shared_container_mutation_once_token, ^{
        s_shared_container_mutation_queue = dispatch_queue_create("serial.shared.container.mutation", DISPATCH_QUEUE_SERIAL);
    });
    
    return s_shared_container_mutation_queue;
}
