#include "MedusaTaskProxy.h"
#include <cassert>
#include <cstdlib>

//#define TRACE_PROXY 1

MedusaTaskProxy::MedusaTaskProxy(std::function<void()> task)
	: taskBlock(std::move(task))
{
}

MedusaTaskProxy::~MedusaTaskProxy()
{
#if TRACE_PROXY
	printf("dealloc MedusaTaskProxy = %p\n", this);
#endif
	free(inputs);
	free(outputs);
}

void MedusaTaskProxy::executeTask()
{
#if TRACE_PROXY
	printf("executing MedusaTaskProxy = %p\n", this);
#endif
	assert(!executed);

	taskBlock();
	executed = true;

	// Single-threaded path: freeing here is cheap (no cross-thread penalty).
	taskBlock = nullptr;
}

#if ENABLE_DEBUG_DUMP
void MedusaTaskProxy::dumpDescription() const
{
	printf("MedusaTaskProxy self=%p\n", this);

	printf("  inputs:\n");
	for(size_t i = 0; i < inputCount; i++)
	{
		printf("    ");
		DumpBranchForNode(inputs[i]);
	}

	printf("  outputs:\n");
	for(size_t i = 0; i < outputCount; i++)
	{
		printf("    ");
		DumpBranchForNode(outputs[i]);
	}
}
#endif
