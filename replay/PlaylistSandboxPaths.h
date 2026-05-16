//
//  PlaylistSandboxPaths.h
//
//  Pre-sandbox playlist scan: reads the playlist file before the sandbox is
//  applied and classifies every path referenced by any action into read-only
//  (inputs) or read-write (outputs / mutating / exclusive inputs). Callers
//  merge the resulting vectors into the sandbox::Config before calling
//  sandbox::InitializeSandbox(), eliminating the need for users to repeat
//  every path with --sandbox-allow-* flags.
//

#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
#include <string>
#include <unordered_map>
#include <vector>

void ExtractPlaylistSandboxPaths(const char *playlist_path,
                                  NSArray<NSString*> *playlist_keys,
                                  const std::unordered_map<std::string, std::string> &env,
                                  std::vector<std::string>& reads,
                                  std::vector<std::string>& writes);

#endif  // __cplusplus
