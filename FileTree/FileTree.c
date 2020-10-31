#include "FileTree.h"

Boolean FileNodeEqualCallBack(const void *value1, const void *value2)
{
	Boolean nodesEqual = false;
	const FileNode *node1 = (const FileNode *)value1;
	const FileNode *node2 = (const FileNode *)value2;

	if((node1->nameLength == node2->nameLength) && (node1->nameChunks[0] == node2->nameChunks[0]))
	{
		//the same name length and first chunks equal. check the remaining chunks, if any
		uint64_t equalCount = 1;
		uint64_t chunkCount = ((uint64_t)node1->nameLength + sizeof(uint64_t)-1) / sizeof(uint64_t);
		while((equalCount < chunkCount) && (node1->nameChunks[equalCount] == node2->nameChunks[equalCount]))
		{
			equalCount++;
		}
		nodesEqual = (equalCount == chunkCount);//all chunks were equal
	}
	return nodesEqual;
}

CFHashCode FileNodeHashCallBack(const void *value)
{
	CFHashCode outHash = 0; //CFHashCode is unsigned long so the same as uint64_t nameChunks
	const FileNode *node = (const FileNode *)value;
	uint64_t chunkCount = ((uint64_t)node->nameLength + sizeof(uint64_t)-1) / sizeof(uint64_t);
	for(uint64_t i = 0; i < chunkCount; i++)
	{
		outHash += node->nameChunks[i];
	}
	return outHash;
}

CFSetCallBacks kFileNodeCFSetCallbacks =
{
    0, // version
    NULL, // retain
    NULL, // release
    NULL, // copyDescription
    FileNodeEqualCallBack,
    FileNodeHashCallBack
};



static inline FileNode*
CreateNodeForDirEntry(const char* dirEntryName, size_t nameLength)
{
	uint64_t chunkCount = ((uint64_t)nameLength + sizeof(uint64_t)-1) / sizeof(uint64_t);
	//One mandatory 8-char name chunk is already in the structure. Extend by as many chunks as needed
	size_t nodeSize = sizeof(FileNode) + (chunkCount - 1)*sizeof(uint64_t);
	
	// calloc() only takes 1.1% of the whole algorithom time
	// optimizing with custom memory manager would not help
	FileNode *outNode = (FileNode *)calloc(1, nodeSize);
	if(outNode == NULL)
		return NULL;
	outNode->nameLength = (uint32_t)nameLength;
	memcpy(outNode->name, dirEntryName, nameLength);
	return outNode;
}

//on-stack version of the above CreateNodeForDirEntry
#define AllocaFileNode(_stackNode, _dirEntryName, _nameLength) \
uint64_t _chunkCount = ((uint64_t)_nameLength + sizeof(uint64_t)-1) / sizeof(uint64_t); \
size_t _nodeSize = sizeof(FileNode) + (_chunkCount - 1)*sizeof(uint64_t); \
_stackNode = (FileNode *)alloca(_nodeSize); \
_stackNode->nameLength = (uint32_t)_nameLength; \
memcpy(_stackNode->name, _dirEntryName, _nameLength); \
size_t _filledChunkBytes = _nameLength % sizeof(uint64_t); \
size_t _bytesToFill = (_filledChunkBytes == 0) ? 0 : (sizeof(uint64_t) - _filledChunkBytes); \
for(size_t _i = 0; _i < _bytesToFill; _i++) \
	{ ((char*)_stackNode->nameChunks)[_nameLength+_i] = 0; }


static inline FileNode *
FindOrCreateChildNode(FileNode *parentNode, const uint64_t *nameChunks, size_t nameLength)
{
	FileNode *foundNode = NULL;
	//FileNode *tempNode = NULL;
	if(parentNode->children == NULL)
	{
		parentNode->children = CFSetCreateMutable(kCFAllocatorDefault, 0, &kFileNodeCFSetCallbacks);
	}
	else
	{
		// temporary on-stack node to find
		FileNode *stackNode;
		AllocaFileNode(stackNode, nameChunks, nameLength);
		foundNode = (FileNode *)CFSetGetValue(parentNode->children, stackNode);
	}

	if(foundNode == NULL)
	{
		foundNode = CreateNodeForDirEntry((const char*)nameChunks, nameLength);
		foundNode->parent = parentNode;
		CFSetAddValue(parentNode->children, foundNode);
	}

	return foundNode;
}

//Public API
FileNode * CreateTreeRoot(void)
{
	return CreateNodeForDirEntry("/", 1);
}

//Public API
FileNode *
FindOrInsertFileNodeForPath(FileNode *treeRoot, const char *filePath)
{
	uint64_t chunkBuffer[256]; //enough to hold 2048 characters, more than enough for each chunk
	//file path must be absolute at this point
	const char *entryName = filePath;
	
	FileNode *entryNode = treeRoot;
	//chop the path into smaller dir entries between separators, find or add nodes up to the deepest one
	do
	{
		while(entryName[0] == '/')//skip all forward slashes until we get a non-slash char or end
			entryName++;

		size_t nameLength = 0;
		while((entryName[nameLength] != '/') && (entryName[nameLength] != 0))
		{
			((char*)chunkBuffer)[nameLength] = entryName[nameLength];
			nameLength++;
		}
		
		// fill the reminder of chunk buffer with 0s
		// so the 64-bit chunk-by-chunk comparison works as expected
		size_t filledChunkBytes = nameLength % sizeof(uint64_t);
		size_t bytesToFill = (filledChunkBytes == 0) ? 0 : (sizeof(uint64_t) - filledChunkBytes);
		
		for(size_t i = 0; i < bytesToFill; i++)
		{
			((char*)chunkBuffer)[nameLength+i] = 0;
		}
		
		if(nameLength > 0)
		{
			entryNode = FindOrCreateChildNode(entryNode, chunkBuffer, nameLength);
			//this must succeed or we are out of memory to construct the file tree
			if(entryNode == NULL)
				return NULL;

			entryName += nameLength;
		}
	}
	while(entryName[0] != 0);

	return entryNode; //this is the deepest child found
}
