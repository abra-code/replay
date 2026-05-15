//
//  FileTree.h
//  FileTree
//
//  Created by Tomasz Kukielka on 10/31/20.
//

#ifndef FileTree_h
#define FileTree_h

#include <stddef.h>
#include <stdint.h>
#include <unordered_set>

// std::unordered_set proved to be at least as performant as the previous
// CFMutableSetRef implementation for the 700,000-path ~/Library benchmark
// former timings:
//   - linked list implementation 11s
//   - CFMutableSet 3.6s (3s of which was in lowercase + posix path extraction)
//   - unordered_set on M1 Pro, 645K ~/Library paths: lowercase 0.19s, tree construction 0.38s

struct FileNode;

struct FileNodeHash
{
	size_t operator()(const FileNode *node) const noexcept;
};

struct FileNodeEq
{
	bool operator()(const FileNode *a, const FileNode *b) const noexcept;
};

using FileNodeChildren = std::unordered_set<FileNode *, FileNodeHash, FileNodeEq>;

struct FileNode
{
	FileNode *parent;
	FileNodeChildren *children; // lazily allocated; nullptr until the first child is added
	void *producer; //different producer object depending on implementation

	uint8_t anyParentHasProducer;
	uint8_t isExclusiveInput; //some consumers demand nodes to be exclusive inputs. e.g. delete or move - nobody else can use deleted or moved item
	uint8_t hasConsumer;
	uint8_t padding;
	uint32_t nameLength;

	union
	{
		char name[sizeof(uint64_t)]; //variable length UTF-8 buffer in chunks of 8 bytes
		//for comparison as 64-bit integers, or 8-char chunks, must be padded by 0s after string
		uint64_t nameChunks[1];
	};
};

// FileNode is a variable size structure with one name chunk in the base declaration
// and the additional ones following in memory if needed

// caller should hold to the tree for as long as needed
FileNode * CreateFileTreeRoot();

// free the constructed tree memory
void DeleteFileTree(FileNode *treeRoot);

// call FindOrInsertFileNodeForPath() repeatedly with paths to construct in-memory tree
FileNode * FindOrInsertFileNodeForPath(FileNode *treeRoot, const char *filePath);

void GetPathForNode(FileNode *fileNode, char *outBuff, size_t outBuffSize);

#if ENABLE_DEBUG_DUMP
// debug to see the node branch
void DumpBranchForNode(FileNode *fileNode);
#endif

#endif /* FileTree_h */
