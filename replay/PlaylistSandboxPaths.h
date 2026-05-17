//
//  PlaylistSandboxPaths.h
//
//  Pre-sandbox playlist scan: classifies every path referenced by actions
//  into read-only (inputs) or read-write (outputs/mutating/exclusive inputs).
//  Callers merge the resulting vectors into the sandbox::Config before calling
//  sandbox::InitializeSandbox(), eliminating the need for users to repeat
//  every path with --sandbox-allow-* flags.
//
//  Phase 5b: accepts already-loaded ActionStep vector — the playlist is loaded
//  once in main() and reused for both sandbox extraction and execution.
//

#pragma once

#include "ActionStep.h"
#include <string>
#include <unordered_map>
#include <vector>

void ExtractPlaylistSandboxPaths(const std::vector<ActionStep>& steps,
                                  const std::unordered_map<std::string, std::string>& env,
                                  std::vector<std::string>& reads,
                                  std::vector<std::string>& writes);
