#include <stdio.h>
#include <time.h>
#include "FileTree.h"

@import Foundation;
@import os.signpost;

//for 0-998 siblings, put count in the sibling index slot, for >= 999, put in 999 slot
static uint32_t sSiblingStatCount[1000];

void
SetProducerForFilePath(FileNode *parentNode, const char *filePath, uint64_t producerIndex)
{
	FileNode *entryNode = FindOrInsertFileNodeForPath(parentNode, filePath);
	if(entryNode != NULL)
	{
		entryNode->producerIndex = producerIndex;
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

	FileNode* rootNode = CreateTreeRoot();

	uint64_t myProducerIndex = 12345;
	for (__weak NSString *testPath in testPaths)
	{
		NSString *lowercasePath = [testPath lowercaseString];
		const char *posixPath = [lowercasePath fileSystemRepresentation];
		SetProducerForFilePath(rootNode, posixPath, myProducerIndex);
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
