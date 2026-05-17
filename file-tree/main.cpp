//#define ENABLE_DEBUG_DUMP 1

#include <stdio.h>
#include <time.h>
#include <algorithm>
#include <cctype>
#include <filesystem>
#include <pwd.h>
#include <string>
#include <vector>
#include <CoreFoundation/CoreFoundation.h>
#include "../common/include/CFObj.h"
#include "FileTree.h"
#include "../common/include/ReplaySignpost.h"

static uint32_t sSiblingStatCount[1000];

void
SetProducerForFilePath(FileNode *parentNode, const char *filePath, uint64_t producerIndex)
{
	FileNode *entryNode = FindOrInsertFileNodeForPath(parentNode, filePath);
	if (entryNode != nullptr)
	{
		entryNode->producer = (void *)producerIndex;
	}
}

std::vector<std::string>
AllFilesInUserLibrary(void)
{
	std::vector<std::string> paths;

	struct passwd *pw = getpwuid(getuid());
	std::filesystem::path libraryDir = std::string(pw->pw_dir) + "/Library";

	// Manual DFS with per-level directory_iterator so an access error in one
	// subtree (EPERM, EACCES) doesn't abort traversal of sibling directories.
	// recursive_directory_iterator::increment(ec) becomes end on the first error.
	std::vector<std::filesystem::path> dirStack;
	dirStack.push_back(libraryDir);

	size_t count = 0;
	while (!dirStack.empty())
	{
		std::filesystem::path dir = std::move(dirStack.back());
		dirStack.pop_back();

		std::error_code ec;
		std::filesystem::directory_iterator it(dir, ec);
		if (ec)
			continue; // can't open this directory — skip it

		while (it != std::filesystem::end(it))
		{
			paths.push_back(it->path().lexically_relative(libraryDir).string());
			count++;
			if ((count % 100000) == 0)
			{
				printf("Found %lu items\n", (unsigned long)count);
			}

			std::error_code statEc;
			std::filesystem::file_status st = it->symlink_status(statEc);
			if (!statEc && st.type() == std::filesystem::file_type::directory)
				dirStack.push_back(it->path());

			it.increment(ec);
			if (ec)
			{
				ec.clear();
				break; // skip remaining entries in this directory
			}
		}
	}
	return paths;
}

std::vector<std::string>
LoadPathsFromPlist(const char *filePath)
{
	std::vector<std::string> paths;

	CFObj<CFURLRef> url(CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
		(const UInt8 *)filePath, (CFIndex)strlen(filePath), false));
	if (url == nullptr)
		return paths;

	CFObj<CFReadStreamRef> stream(CFReadStreamCreateWithFile(kCFAllocatorDefault, url));
	if (stream == nullptr)
		return paths;

	CFReadStreamOpen(stream);
	CFObj<CFPropertyListRef> plist(CFPropertyListCreateWithStream(kCFAllocatorDefault,
		stream, 0, kCFPropertyListImmutable, nullptr, nullptr));
	CFReadStreamClose(stream);

	if (plist != nullptr)
	{
		if (CFGetTypeID(plist) == CFArrayGetTypeID())
		{
			CFArrayRef array = (CFArrayRef)plist.Get();
			CFIndex count = CFArrayGetCount(array);
			char buf[4096];
			for (CFIndex i = 0; i < count; i++)
			{
				CFStringRef str = (CFStringRef)CFArrayGetValueAtIndex(array, i);
				if (CFStringGetFileSystemRepresentation(str, buf, (CFIndex)sizeof(buf)))
				{
					paths.push_back(buf);
				}
			}
		}
	}
	return paths;
}

void CountSiblingNodes(const FileNode *parentNode)
{
	uint64_t currentSiblingCount = (parentNode->children != nullptr) ? (uint64_t)parentNode->children->size() : 0;

	if (currentSiblingCount < 998)
		sSiblingStatCount[currentSiblingCount] += 1;
	else
		sSiblingStatCount[999] += 1;

	if (parentNode->children != nullptr)
	{
		for (FileNode *child : *parentNode->children)
		{
			CountSiblingNodes(child);
		}
	}
}

int main(int argc, const char * argv[])
{
	std::vector<std::string> testPaths;

	if (argc < 2)
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
		testPaths = LoadPathsFromPlist(argv[1]);
	}

	printf("Loaded %lu test paths\n", (unsigned long)testPaths.size());

	REPLAY_SIGNPOST_EVENT("lowercasing and fileSystemRepresentation");

	// run lowercasing separately first just to assess how long it takes
	{
		clock_t posixBegin = clock();
		for (const std::string& testPath : testPaths)
		{
			std::string lowercasePath = testPath;
			std::transform(lowercasePath.begin(), lowercasePath.end(), lowercasePath.begin(),
				[](unsigned char c) { return (char)tolower(c); });
			(void)lowercasePath.c_str();
		}
		clock_t posixEnd = clock();
		double posixSeconds = (double)(posixEnd - posixBegin) / CLOCKS_PER_SEC;
		printf("Lowercase and posix path extraction takes %f seconds\n", posixSeconds);
	}

	printf("Creating file tree for test paths\n");

	clock_t begin = clock();

	REPLAY_SIGNPOST_EVENT("Creating file tree");

	FileNode *rootNode = CreateFileTreeRoot();

	uint64_t myProducerIndex = 12345;
	for (const std::string& testPath : testPaths)
	{
		std::string lowercasePath = testPath;
		std::transform(lowercasePath.begin(), lowercasePath.end(), lowercasePath.begin(),
			[](unsigned char c) { return (char)tolower(c); });
		SetProducerForFilePath(rootNode, lowercasePath.c_str(), myProducerIndex);
	}

	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
	printf("Finished creating file tree in %f seconds\n", seconds);

	printf("Gathering file node stats\n");
	clock_t statsBegin = clock();

	REPLAY_SIGNPOST_EVENT("Begin gathering file node stats");

	CountSiblingNodes(rootNode);

	REPLAY_SIGNPOST_EVENT("End gathering file node stats");

	clock_t statsEnd = clock();
	double statsSeconds = (double)(statsEnd - statsBegin) / CLOCKS_PER_SEC;
	printf("Finished walking the whole tree with node comparisons in %f seconds\n", statsSeconds);

	printf("Tsv with how many directories with given sibling count:\n");
	printf("siblings\tdirs count\n");
	for (int i = 0; i < 1000; i++)
	{
		printf("%d\t%u\n", i, sSiblingStatCount[i]);
	}

	return 0;
}
