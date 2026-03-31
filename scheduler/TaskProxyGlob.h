//
//  TaskProxyGlob.h
//
//  C++ accessor declarations for TaskProxy's glob pattern storage.
//  Only include from .mm files — uses C++ types.
//

#import "TaskProxy.h"
#include <string>
#include <vector>

// Glob patterns for dependency analysis.
// Paths containing wildcards (*, ?, [, {) are stored here instead of in the FileTree,
// since glob patterns can't be inserted as concrete nodes.
// The overlap between glob inputs/outputs across tasks is resolved by
// NFA product construction (see GlobOverlap.h).

@interface TaskProxy (Glob)

- (const std::vector<std::string>&)globInputs;
- (void)setGlobInputs:(std::vector<std::string>)inputs;

- (const std::vector<std::string>&)globExclusiveInputs;
- (void)setGlobExclusiveInputs:(std::vector<std::string>)inputs;

- (const std::vector<std::string>&)globOutputs;
- (void)setGlobOutputs:(std::vector<std::string>)outputs;

@end
