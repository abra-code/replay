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
