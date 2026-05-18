#include "RecursiveMedusa.h"
#include <cassert>
#include <cstdio>
#include <ctime>

void IndexAllOutputsForRecursiveExecution(const std::vector<MedusaTaskProxy*>& allTasks,
                                          OutputInfo* outputInfoArray, size_t outputArrayCount)
{
	printf("First pass to index all output files\n");
	clock_t begin = clock();
	size_t outputIndex = 0;
	for(MedusaTaskProxy* oneTask : allTasks)
	{
		FileNode** outputs = oneTask->outputs;
		for(size_t i = 0; i < oneTask->outputCount; i++)
		{
			FileNode* node = outputs[i];
			assert(outputIndex < outputArrayCount);
			OutputInfo* outputProducer = &(outputInfoArray[outputIndex]);
			outputProducer->producer = oneTask;
			outputIndex++;
			// No two producers can produce the same output.
			assert(node->producer == nullptr);
			// Store OutputInfo* so the node can later be found as someone's input.
			node->producer = outputProducer;
		}
	}

	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
	printf("Total number of outputs in all medusas %zu\n", outputIndex);
	printf("Finished indexing all outputs in %f seconds\n", seconds);
}


static void FileNodeCFSetConnectConsumers(FileNode* node, void* producerContext)
{
	if(producerContext != nullptr)
	{
		node->anyParentHasProducer = 1;
		if(node->producer != nullptr)
		{
			OutputInfo* parentProducerInfo = static_cast<OutputInfo*>(producerContext);
			OutputInfo* currProducerInfo   = static_cast<OutputInfo*>(node->producer);
			parentProducerInfo->consumers.insert(currProducerInfo->producer);
		}
	}

	if(node->children != nullptr)
	{
		if(node->producer != nullptr)
			producerContext = node->producer;

		for(FileNode* child : *node->children)
			FileNodeCFSetConnectConsumers(child, producerContext);
	}
}

void
ConnectImplicitProducersForRecursiveExecution(FileNode* treeRoot)
{
	printf("Connecting implicit producers\n");
	clock_t begin = clock();

	if(treeRoot->children != nullptr)
	{
		void* producerContext = treeRoot->producer;
		for(FileNode* child : *treeRoot->children)
			FileNodeCFSetConnectConsumers(child, producerContext);
	}

	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
	printf("Finished connecting implicit producers in %f seconds\n", seconds);
}


std::unordered_set<MedusaTaskProxy*>
ConnectDynamicInputsForRecursiveExecution(const std::vector<MedusaTaskProxy*>& allTasks)
{
	printf("Connecting all dynamic inputs\n");
	clock_t begin = clock();
	size_t all_input_count = 0;
	size_t static_input_count = 0;

	std::unordered_set<MedusaTaskProxy*> staticInputTasks;

	for(MedusaTaskProxy* oneTask : allTasks)
	{
		bool are_all_inputs_satisfied = true;

		FileNode** inputs = oneTask->inputs;
		for(size_t i = 0; i < oneTask->inputCount; i++)
		{
			FileNode* node = inputs[i];
			all_input_count++;

			OutputInfo* outputProducer = static_cast<OutputInfo*>(node->producer);
			if(outputProducer != nullptr)
			{
				outputProducer->consumers.insert(oneTask);
			}
			else if(node->anyParentHasProducer)
			{
				FileNode* parentNode = node->parent;
				while(parentNode != nullptr)
				{
					if(parentNode->producer != nullptr)
					{
						outputProducer = static_cast<OutputInfo*>(parentNode->producer);
						outputProducer->consumers.insert(oneTask);
						break;
					}
					parentNode = parentNode->parent;
				}
			}
			else
			{
				static_input_count++;
			}

			are_all_inputs_satisfied = (are_all_inputs_satisfied && (outputProducer == nullptr));
		}

		if(are_all_inputs_satisfied)
			staticInputTasks.insert(oneTask);
	}

	clock_t end = clock();
	double seconds = (double)(end - begin) / CLOCKS_PER_SEC;
	printf("Finished connecting all dynamic outputs in %f seconds\n", seconds);
	printf("All input count %zu\n", all_input_count);
	printf("Static input count %zu\n", static_input_count);
	printf("Initial count of medusas with static dependencies only: %zu\n", staticInputTasks.size());

	return staticInputTasks;
}


void ExecuteMedusaGraphRecursively(std::unordered_set<MedusaTaskProxy*> taskSet)
{
	std::unordered_set<MedusaTaskProxy*> nextTaskSet;
	for(MedusaTaskProxy* oneTask : taskSet)
	{
#if ENABLE_DEBUG_DUMP
		oneTask->dumpDescription();
#endif
		oneTask->executeTask();

		FileNode** outputs = oneTask->outputs;
		for(size_t i = 0; i < oneTask->outputCount; i++)
		{
			FileNode* outputNode = outputs[i];
			OutputInfo* outputProducer = static_cast<OutputInfo*>(outputNode->producer);

			for(MedusaTaskProxy* consumerTask : outputProducer->consumers)
			{
				if(consumerTask->executed)
					continue;

				bool are_all_inputs_satisfied = true;

				FileNode** inputs = consumerTask->inputs;
				for(size_t j = 0; j < consumerTask->inputCount; j++)
				{
					FileNode* inputNode = inputs[j];
					OutputInfo* oneProducer = static_cast<OutputInfo*>(inputNode->producer);
					bool is_input_satisfied = (oneProducer == nullptr); // static input
					if(oneProducer != nullptr)
						is_input_satisfied = oneProducer->producer->executed;
					are_all_inputs_satisfied = (are_all_inputs_satisfied && is_input_satisfied);
					if(!are_all_inputs_satisfied)
						break;
				}

				if(are_all_inputs_satisfied)
					nextTaskSet.insert(consumerTask);
			}
		}
	}

	if(!nextTaskSet.empty())
		ExecuteMedusaGraphRecursively(std::move(nextTaskSet));
}

#if ENABLE_DEBUG_DUMP

static void DumpOneRecursiveTaskLevel(const std::unordered_set<MedusaTaskProxy*>& taskSet, int level)
{
	for(MedusaTaskProxy* oneTask : taskSet)
	{
		for(int l = 0; l < level; l++) printf("  ");
		printf("MedusaTaskProxy=%p\n", oneTask);
		FileNode** outputs = oneTask->outputs;
		for(size_t i = 0; i < oneTask->outputCount; i++)
		{
			FileNode* outputNode = outputs[i];
			for(int l = 0; l < (level+1); l++) printf("  ");
			printf("consumers of output %zu: ", i);
			DumpBranchForNode(outputNode);

			OutputInfo* outputProducerInfo = static_cast<OutputInfo*>(outputNode->producer);
			DumpOneRecursiveTaskLevel(outputProducerInfo->consumers, level+2);
		}
	}
}

void DumpRecursiveTaskTree(const std::unordered_set<MedusaTaskProxy*>& rootTaskSet)
{
	printf("---------------------------\n");
	printf("Dumping recursive task tree:\n");
	DumpOneRecursiveTaskLevel(rootTaskSet, 0);
	printf("---------------------------\n");
}

#endif // ENABLE_DEBUG_DUMP
