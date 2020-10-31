//
//  FileTree.h
//  FileTree
//
//  Created by Tomasz Kukielka on 10/31/20.
//

#ifndef FileTree_h
#define FileTree_h

#include <CoreFoundation/CoreFoundation.h>

// CFSet proved to be much more performant than the linked list of siblings
// for ~700,000 file paths found in ~/Library, creating the tree in release build took as follows:
// - linked list verion: 11 secs
// - CFSet version:      3.6 secs
// but 3 secs in each case were spent on lowercasing and posix path extraction!

typedef struct FileNode
{
	struct FileNode *parent;
	CFMutableSetRef children;
	uint64_t producerIndex;
	
	uint8_t anyParentHasProducer;
	uint8_t padding[3];
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

//caller should hold to the tree for as long as needed
FileNode * CreateTreeRoot(void);

//call FindOrInsertFileNodeForPath() repeatedly with paths to construct in-memory tree
FileNode * FindOrInsertFileNodeForPath(FileNode *treeRoot, const char *filePath);

#endif /* FileTree_h */