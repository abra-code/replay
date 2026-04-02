//
//  FileTree.h
//  FileTree
//
//  Created by Tomasz Kukielka on 10/31/20.
//

#ifndef FileTree_h
#define FileTree_h

#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// CFSet proved to be much more performant than the linked list of siblings
// for ~700,000 file paths found in ~/Library, creating the tree in release build took as follows:
// - linked list verion: 11 secs
// - CFSet version:      3.6 secs
// but 3 secs in each case were spent on lowercasing and posix path extraction!

typedef struct FileNode
{
	struct FileNode *parent;
	CFMutableSetRef children;
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
} FileNode;

// FileNode is a variable size structure with one name chunk in the base declaration
// and the additional ones following in memory if needed

// caller should hold to the tree for as long as needed
FileNode * CreateFileTreeRoot(void);

// free the constructed tree memory
void DeleteFileTree(FileNode *treeRoot);

// call FindOrInsertFileNodeForPath() repeatedly with paths to construct in-memory tree
FileNode * FindOrInsertFileNodeForPath(FileNode *treeRoot, const char *filePath);

void GetPathForNode(FileNode *fileNode, char *outBuff, size_t outBuffSize);

#if ENABLE_DEBUG_DUMP
// debug to see the node branch
void DumpBranchForNode(FileNode *fileNode);
#endif

#ifdef __cplusplus
}
#endif

#endif /* FileTree_h */
