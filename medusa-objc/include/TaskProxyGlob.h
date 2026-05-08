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

- (const std::vector<std::string>&)globMutatingInputs;
- (void)setGlobMutatingInputs:(std::vector<std::string>)inputs;

// Concrete (non-glob) paths used as mutating inputs by this task.
// Stored as lowercase POSIX paths to match GetPathForNode output for
// pattern_overlap / concrete_matches_glob comparisons in the scheduler.
- (const std::vector<std::string>&)concreteMutatingPaths;
- (void)setConcreteMutatingPaths:(std::vector<std::string>)paths;

- (const std::vector<std::string>&)globOutputs;
- (void)setGlobOutputs:(std::vector<std::string>)outputs;

@end
