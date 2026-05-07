#pragma once
#include <string>
#include <vector>

struct DirEntry {
	std::string name;
	bool isDirectory;
};

// List direct children of path, sorted alphabetically.
// Skips "." and "..". Follows symlinks for type detection.
// Returns false and sets errno on failure.
bool list_directory(const char *path, std::vector<DirEntry> &out_entries);

struct TreeNode {
	std::string name;
	bool isDirectory;
	std::vector<TreeNode> children; // populated only when isDirectory
};

// Build a tree rooted at path using fts_read (iterative, no recursion).
// Root node name is derived from the last path component.
// maxDepth controls depth: 0 = root node only (no children), 1 = immediate children, etc.
// Returns false if fts_open fails. Unreadable subdirectories are silently skipped.
bool build_directory_tree(const char *path, TreeNode &out_root, int maxDepth);

// Expand a single absolute glob pattern (e.g. /src/**/*.swift) to matching absolute paths.
// Case-insensitive (macOS APFS default). Returns sorted results.
std::vector<std::string> expand_glob(const std::string &pattern);

// Search files matching any positive pattern, excluding paths that match any exclude pattern.
// Exclude patterns use the same glob engine as positive patterns (glob::glob / glob_match,
// case-insensitive). Matching rules:
//   - Patterns without '/': matched against the filename (last path component) only.
//     e.g. '*.generated.swift' excludes any file whose name ends in '.generated.swift'.
//   - Patterns with '/': the concrete prefix is extracted and the glob suffix is matched
//     against the relative path from that prefix (same as positive pattern expansion).
//     e.g. '/src/build/*.o' or '${SRC}/build/*.o'.
// Returns sorted, deduplicated paths. max_results=0 means unlimited.
std::vector<std::string> search_files(
	const std::vector<std::string> &patterns,
	const std::vector<std::string> &exclude_patterns,
	size_t max_results = 1000);

// Walk root_dir, returning files that match any relative glob pattern (matched against the
// path relative to root_dir). Exclude patterns follow the same rules as compile_excludes:
//   - no '/': basename-only glob (e.g. '*.gen.swift' matches any depth)
//   - with '/': relative path glob matched against the path relative to root_dir
// Results are sorted and deduplicated. max_results=0 means unlimited.
std::vector<std::string> glob_files_in_dir(
	const std::string &root_dir,
	const std::vector<std::string> &relative_glob_patterns,
	const std::vector<std::string> &exclude_patterns,
	size_t max_results = 1000);
