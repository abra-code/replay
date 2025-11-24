//
//  dispatch_queues_helper.h
//  fingerprint
//
//  Created by Tomasz Kukielka on 10/9/25.
//

#pragma once
#include <dispatch/dispatch.h>

// all tasks must be added to a group so we can wait for all to finish at the end
dispatch_group_t get_all_tasks_group() noexcept;

// concurrent directory traversal queue for the long running readdir task (only single one in current design)
dispatch_queue_t get_directory_traversal_queue() noexcept;

// CPU gate queue and its counting semaphore is limiting the number
// of concurrent tasks to the number of cores because the hashing
// algorithms use ARM NEON for SIMD
dispatch_queue_t get_cpu_gate_queue() noexcept;
dispatch_semaphore_t get_concurrency_semaphore() noexcept;

// concurrent queue to dispatch file processing tasks to
dispatch_queue_t get_file_processing_queue() noexcept;

// serial queue for thread-safe shared container mutation
dispatch_queue_t get_shared_container_mutation_queue() noexcept;
