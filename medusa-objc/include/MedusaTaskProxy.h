#pragma once
#include "FileTree.h"
#include <functional>

// Single-threaded recursive execution task node (not used in the concurrent scheduler path).
struct MedusaTaskProxy {
	std::function<void()> taskBlock;
	FileNode** inputs = nullptr;
	size_t inputCount = 0;
	FileNode** outputs = nullptr;
	size_t outputCount = 0;
	bool executed = false;

	explicit MedusaTaskProxy(std::function<void()> task);
	~MedusaTaskProxy();

	MedusaTaskProxy(const MedusaTaskProxy&) = delete;
	MedusaTaskProxy& operator=(const MedusaTaskProxy&) = delete;

	void executeTask();

#if ENABLE_DEBUG_DUMP
	void dumpDescription() const;
#endif
};
