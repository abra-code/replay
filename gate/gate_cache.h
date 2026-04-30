//
//  gate_cache.h
//  gate
//
//  Persistent cache for gate task fingerprints.
//  Each task gets its own cache file named by its signature hash.
//

#pragma once

#include <string>
#include <vector>
#include <cstdint>

enum class CacheFormat
{
    Plist,  // binary plist (default) — compact, fast
    Json    // JSON — human-readable, good for debugging
};

struct CacheEntry
{
    std::string command;
    std::vector<std::string> inputs;
    std::vector<std::string> outputs;
    std::vector<std::string> exclude_inputs;
    uint64_t input_fingerprint;
    uint64_t output_fingerprint;
    std::string hash_algorithm;
    std::string timestamp;
};

// Compute the task signature (16-char hex) from all identity parameters.
// This determines the per-task cache filename.
// signature_keys: additional arbitrary strings that distinguish task variants
//                 (e.g. build configuration, architecture).
// exclude_inputs: paths/globs subtracted from inputs; different exclude sets
//                 produce different task signatures.
std::string compute_task_signature(const std::vector<std::string>& inputs,
                                   const std::vector<std::string>& outputs,
                                   const std::vector<std::string>& exclude_inputs,
                                   const std::string& command,
                                   const std::string& hash_algorithm,
                                   const std::vector<std::string>& signature_keys);

// Look up a cache entry by signature. Returns true if found.
bool cache_lookup(const std::string& cache_dir,
                  CacheFormat format,
                  const std::string& signature,
                  CacheEntry& out_entry);

// Store a cache entry by signature. Creates cache_dir if needed.
// Uses atomic write (temp file + rename) and flock for concurrency.
bool cache_store(const std::string& cache_dir,
                 CacheFormat format,
                 const std::string& signature,
                 const CacheEntry& entry);
