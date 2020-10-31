#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <time.h>
@import Foundation;
@import os.signpost;

//for 0-998 siblings, put count in the sibling index slot, for >= 999, put in 999 slot
static uint32_t sSiblingStatCount[1000];

// CFSet proved to be much more performant than the linked list of siblings
// for ~700,000 file paths found in ~/Library, creating the tree in release build took as follows:
// - linked list verion: 11 secs
// - CFSet version:      3.6 secs
// but 3 secs in each case were spent on lowercasing and posix path extraction!

#define USE_CFSET 1

typedef struct Producer
{
	uint64_t id;
} Producer;

typedef struct FileNode
{
	struct FileNode *parent;

#if USE_CFSET
	CFMutableSetRef children;
#else
	struct FileNode *sibling;
	struct FileNode *child;
#endif
	struct Producer *producer;
	
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

#if USE_CFSET
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
#endif //USE_CFSET



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

#if USE_CFSET

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
		//if(tempNode == NULL)
			foundNode = CreateNodeForDirEntry((const char*)nameChunks, nameLength);
		//else
		//	foundNode = tempNode;
		foundNode->parent = parentNode;
		CFSetAddValue(parentNode->children, foundNode);
	}

	return foundNode;
}

#else //USE_CFSET

static inline FileNode *
FindOrCreateChildNode(FileNode *parentNode, const uint64_t *nameChunks, size_t nameLength)
{
	bool isNodeFound = false;
	FileNode *currSibling = parentNode->child;
	while(currSibling != NULL)
	{//each node must have at least one chunk so it is quick to check the len and the first chunk
		if((nameLength == currSibling->nameLength) && (nameChunks[0] == currSibling->nameChunks[0]))
		{
			//found non-null sibling of the same name length and first chunks equal
			//check the remaining chunks, if any
			uint64_t equalCount = 1;
			uint64_t chunkCount = ((uint64_t)nameLength + sizeof(uint64_t)-1) / sizeof(uint64_t);
			while((equalCount < chunkCount) && (nameChunks[equalCount] == currSibling->nameChunks[equalCount]))
			{
				equalCount++;
			}
			isNodeFound = (equalCount == chunkCount);//all chunks were equal
		}
		
		if(isNodeFound)
		{
			break;
		}
		
		currSibling = currSibling->sibling;
	}
	
	if(isNodeFound)
	{
		return currSibling;
	}

	FileNode* newEntry = CreateNodeForDirEntry((const char*)nameChunks, nameLength);
	newEntry->parent = parentNode; 
	newEntry->sibling = parentNode->child;//elder siblings
	parentNode->child = newEntry;
	
	return newEntry;
}

#endif //USE_CFSET

void
SetProducerForFilePath(FileNode *parentNode, const char *filePath, struct Producer *producer)
{
	uint64_t chunkBuffer[256]; //enough to hold 2048 characters, more than enough for each chunk
	//file path must be absolute at this point
	const char *entryName = filePath;
	
	FileNode *entryNode = parentNode;
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
				return;

			entryName += nameLength;
		}
	}
	while(entryName[0] != 0);
	
	if(entryNode != NULL) //this is the deepest child found
	{
		entryNode->producer = producer;
	}
}

NSArray<NSString *> *
AllFilesInUserLibrary()
{
	NSMutableArray<NSString *> *itemArray = [NSMutableArray arrayWithCapacity:0];
	NSString *libraryDir = [NSHomeDirectory() stringByAppendingPathComponent:  @"Library"];
	NSFileManager *localFileManager = [NSFileManager defaultManager];
	NSDirectoryEnumerator *libraryEnumarator = [localFileManager enumeratorAtPath:libraryDir];
	
	NSUInteger count = 0;
	NSString *filePath = nil;
	while ((filePath = [libraryEnumarator nextObject]) != nil)
	{
		[itemArray addObject:filePath];
		count++;
		if ((count % 100000) == 0)
		{
			printf("Found %lu items\n", (unsigned long)count );
		}
	}
	return itemArray;
}

#if USE_CFSET

void CountSiblingNodes(const FileNode *parentNode);

void FileNodeCFSetVisitor(const void *value, void *context)
{
	const FileNode *node = (const FileNode *)value;
	CountSiblingNodes(node);
}

void CountSiblingNodes(const FileNode *parentNode)
{
	uint64_t currentSiblingCount = (parentNode->children != NULL) ? CFSetGetCount(parentNode->children) : 0;

	if(currentSiblingCount < 998)
		sSiblingStatCount[currentSiblingCount] += 1;
	else
		sSiblingStatCount[999] += 1;

	if(parentNode->children != NULL)
		CFSetApplyFunction(parentNode->children, FileNodeCFSetVisitor, NULL/*context*/);
}

#else

void CountSiblingNodes(FileNode *parentNode)
{
	uint64_t currentSiblingCount = 0;
	FileNode *currSibling = parentNode->child;
	while(currSibling != NULL)
	{
		currentSiblingCount++;
		
		// while at it, let's spend time comparing all chunks
		// worst case scenario for assessing the perf of walking the whole tree with chunk comparison
		uint64_t equalCount = 0;
		uint64_t chunkCount = ((uint64_t)currSibling->nameLength + sizeof(uint64_t)-1) / sizeof(uint64_t);
		while((equalCount < chunkCount) && (0 != currSibling->nameChunks[equalCount]))
		{
			equalCount++;
		}

		CountSiblingNodes(currSibling);
		currSibling = currSibling->sibling;
	}

	if(currentSiblingCount < 998)
		sSiblingStatCount[currentSiblingCount] += 1;
	else
		sSiblingStatCount[999] += 1;
}

#endif //USE_CFSET

int main(int argc, const char * argv[])
{
	NSArray<NSString*> *testPaths = nil;

	os_log_t log = os_log_create("filetree", OS_LOG_CATEGORY_POINTS_OF_INTEREST);

	if(argc < 2)
	{
		printf("Finding all paths in ~/Library\n");
		clock_t findBegin = clock();
		testPaths = AllFilesInUserLibrary();
		clock_t findEnd = clock();
		double findSeconds = (double)(findEnd - findBegin) / CLOCKS_PER_SEC;
		printf("Finished finding files in %f seconds\n", findSeconds);
	}
	else
	{
		printf("Loading paths from provided plist file\n");
		NSURL *pathsURL = [NSURL fileURLWithFileSystemRepresentation:argv[1] isDirectory:NO relativeToURL:NULL];
		testPaths = [NSArray arrayWithContentsOfURL:pathsURL];
	}

	printf("Loaded %lu test paths\n", (unsigned long)testPaths.count );

	os_signpost_event_emit(log, OS_SIGNPOST_ID_EXCLUSIVE, "lowercasing and fileSystemRepresentation");

	// run lowercasing and fileSystemRepresentation separately first
	// just to assess how long these operations take
	{
		clock_t posixBegin = clock();
		for (__weak NSString *testPath in testPaths)
		{
			NSString *lowercasePath = [testPath lowercaseString];
			const char *posixPath = [lowercasePath fileSystemRepresentation];
			posixPath = posixPath + 1;
		}
		clock_t posixEnd = clock();
		double posixSeconds = (double)(posixEnd - posixBegin) / CLOCKS_PER_SEC;
		printf("Lowercase and posix path extraction takes %f seconds\n", posixSeconds);
	}

	printf("Creating file tree for test paths\n");

 	clock_t begin = clock();
 	
	os_signpost_event_emit(log, OS_SIGNPOST_ID_EXCLUSIVE, "Creating file tree");

	FileNode* rootNode = CreateNodeForDirEntry("/", 1);

	Producer myProducer;
	for (__weak NSString *testPath in testPaths)
	{
		NSString *lowercasePath = [testPath lowercaseString];
		const char *posixPath = [lowercasePath fileSystemRepresentation];
		SetProducerForFilePath(rootNode, posixPath, &myProducer);
	}

	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
    printf("Finished creating file tree in %f seconds\n", seconds);

	printf("Gathering file node stats\n");
	clock_t statsBegin = clock();

	os_signpost_event_emit(log, OS_SIGNPOST_ID_EXCLUSIVE, "Begin gathering file node stats");

	CountSiblingNodes(rootNode);

	os_signpost_event_emit(log, OS_SIGNPOST_ID_EXCLUSIVE, "End gathering file node stats");

	clock_t statsEnd = clock();
	double statsSeconds = (double)(statsEnd - statsBegin) / CLOCKS_PER_SEC;
	printf("Finished walking the whole tree with node comparisons in %f seconds\n", statsSeconds);

	printf("Tsv with how many directories with given sibling count:\n");
	printf("siblings\tdirs count\n");
	for(int i = 0; i < 1000; i++)
	{
		printf("%d\t%u\n", i, sSiblingStatCount[i]);
	}

	return 0;
}
