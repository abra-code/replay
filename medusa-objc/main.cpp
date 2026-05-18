//
//  main.mm
//  medusa-objc
//
//  Created by Tomasz Kukielka on 9/13/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#include "RecursiveMedusa.h"
#include "SchedulerMedusa.h"
#include "MedusaTaskProxy.h"
#include "TaskProxy.h"
#include "TaskScheduler.h"
#include "FileTree.h"

#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <random>
#include <string>
#include <type_traits>
#include <vector>
#include "hi_res_timer.h"

// producer is only set for TaskProxy (concurrent scheduler path); nullptr for MedusaTaskProxy.
static inline FileNode* FileNodeFromPath(FileNode* fileTreeRoot, const char* path, TaskProxy* producer)
{
	char lowercasePath[2048];
	size_t len = strnlen(path, sizeof(lowercasePath) - 1);
	for(size_t i = 0; i < len; i++)
		lowercasePath[i] = (char)tolower((unsigned char)path[i]);
	lowercasePath[len] = '\0';

	FileNode* outNode = FindOrInsertFileNodeForPath(fileTreeRoot, lowercasePath);
	if(producer != nullptr)
	{
		assert(outNode->producer == nullptr);
		outNode->producer = producer; // raw TaskProxy* stored as void*
	}
	return outNode;
}

//#define PRINT_TASK 1
#define TEST_RECURSIVE 1

// Generates task_count tasks of type T (TaskProxy or MedusaTaskProxy) with randomised
// static/dynamic inputs and outputs.  For TaskProxy, sets producer in each output FileNode.
template<typename T>
static std::vector<std::unique_ptr<T>> GenerateTestTasks(
	FileNode* fileTreeRoot,
	size_t task_count,
	size_t max_static_input_count,  // > 0
	size_t max_dynamic_input_count, // >= 0
	size_t max_output_count,        // > 0
	size_t* inputCountPtr,
	size_t* outputCountPtr)
{
	std::cout << "Generating " << task_count << " test tasks\n";
	hi_res_timer timer;

	std::vector<std::unique_ptr<T>> tasks;
	tasks.reserve(task_count + 1);

	size_t inputCount = 0;
	size_t outputCount = 0;

	std::random_device randomizer;
	assert(max_static_input_count > 0);
	std::uniform_int_distribution<size_t> static_input_dist(1, max_static_input_count - 1);
	std::uniform_int_distribution<size_t> dynamic_input_dist(0, max_dynamic_input_count - 1);
	assert(max_output_count > 0);
	std::uniform_int_distribution<size_t> output_dist(1, max_output_count - 1);

	// Directory-creating root task that produces /Static and /Dynamic subtrees.
	auto dir_task = std::make_unique<T>([]() {
#if PRINT_TASK
		printf("executing directory creating task\n");
#endif
	});
	T* dir_ptr = dir_task.get();
	tasks.push_back(std::move(dir_task));

	dir_ptr->outputCount = 2;
	dir_ptr->outputs = (FileNode**)malloc(sizeof(FileNode*) * 2);

	TaskProxy* dir_producer = nullptr;
	if constexpr (std::is_same_v<T, TaskProxy>)
		dir_producer = dir_ptr;
	dir_ptr->outputs[0] = FileNodeFromPath(fileTreeRoot, "/static", dir_producer);
	outputCount++;
	dir_ptr->outputs[1] = FileNodeFromPath(fileTreeRoot, "/dynamic", dir_producer);
	outputCount++;

	char pathBuf[256];
	for(size_t i = 0; i < task_count; i++)
	{
		size_t static_count  = static_input_dist(randomizer);
		size_t dynamic_count = (i < max_dynamic_input_count) ? 0 : dynamic_input_dist(randomizer);
		size_t out_count     = output_dist(randomizer);

		auto one_task = std::make_unique<T>([i]() {
#if PRINT_TASK
			printf("executing task %zu\n", i);
#endif
		});
		T* task_ptr = one_task.get();
		tasks.push_back(std::move(one_task));

		size_t input_count = static_count + dynamic_count;
		FileNode** input_array = (FileNode**)malloc(sizeof(FileNode*) * input_count);

		for(size_t j = 0; j < static_count; j++)
		{
			snprintf(pathBuf, sizeof(pathBuf), "/static/dir-%zu/file-%zu", i, i * 1000 + j);
			input_array[j] = FileNodeFromPath(fileTreeRoot, pathBuf, nullptr);
			inputCount++;
		}

		task_ptr->inputCount = input_count;
		task_ptr->inputs = input_array;

		for(size_t j = 0; j < dynamic_count; j++)
		{
			size_t lower_index = 0;
			size_t lower_out_count = 0;
			std::uniform_int_distribution<size_t> lower_dist(0, i - 1);
			do
			{
				lower_index = lower_dist(randomizer);
				lower_out_count = tasks[lower_index]->outputCount;
			} while(lower_out_count == 0);

			std::uniform_int_distribution<size_t> lower_out_dist(0, lower_out_count - 1);
			size_t out_idx = lower_out_dist(randomizer);
			snprintf(pathBuf, sizeof(pathBuf), "/dynamic/dir-%zu/out-%zu",
			         lower_index, lower_index * 1000 + out_idx);
			input_array[static_count + j] = FileNodeFromPath(fileTreeRoot, pathBuf, nullptr);
			inputCount++;
		}

		FileNode** output_array = (FileNode**)malloc(sizeof(FileNode*) * out_count);

		TaskProxy* producer = nullptr;
		if constexpr (std::is_same_v<T, TaskProxy>)
			producer = task_ptr;

		for(size_t j = 0; j < out_count; j++)
		{
			snprintf(pathBuf, sizeof(pathBuf), "/dynamic/dir-%zu/out-%zu", i, i * 1000 + j);
			output_array[j] = FileNodeFromPath(fileTreeRoot, pathBuf, producer);
			outputCount++;
		}

		task_ptr->outputCount = out_count;
		task_ptr->outputs = output_array;
	}

	double seconds_core = timer.elapsed();

	for(size_t i = 0; i < task_count - 1; i++)
	{
		std::uniform_int_distribution<size_t> dist(0, task_count - i - 1);
		size_t randomIndex = dist(randomizer);
		std::swap(tasks[i], tasks[i + randomIndex]);
	}

	double seconds_shuffled = timer.elapsed();
	std::cout << "Finished task generation in " << seconds_shuffled << " seconds\n";
	std::cout << "Shuffled generated tasks in " << (seconds_shuffled - seconds_core) << " seconds\n";

	if(inputCountPtr != nullptr)
		*inputCountPtr = inputCount;
	if(outputCountPtr != nullptr)
		*outputCountPtr = outputCount;

	return tasks;
}

static void ExecuteMedusasRecursively(
	const std::vector<std::unique_ptr<MedusaTaskProxy>>& tasks,
	FileNode* fileTreeRoot,
	size_t inputCount,
	size_t outputCount)
{
	std::vector<MedusaTaskProxy*> rawTasks;
	rawTasks.reserve(tasks.size());
	for(const auto& t : tasks)
		rawTasks.push_back(t.get());

	// std::vector ensures OutputInfo constructors run (std::unordered_set member
	// requires proper construction; calloc would be UB here).
	std::vector<OutputInfo> outputInfoArray(outputCount);

	IndexAllOutputsForRecursiveExecution(rawTasks, outputInfoArray.data(), outputCount);
	ConnectImplicitProducersForRecursiveExecution(fileTreeRoot);

	std::unordered_set<MedusaTaskProxy*> staticInputTaskSet =
		ConnectDynamicInputsForRecursiveExecution(rawTasks);

#if ENABLE_DEBUG_DUMP
	DumpRecursiveTaskTree(staticInputTaskSet);
#endif

	std::cout << "Following medusa chain recursively\n";
	hi_res_timer timer;
	ExecuteMedusaGraphRecursively(std::move(staticInputTaskSet));
	double seconds = timer.elapsed();
	std::cout << "Finished medusa execution in " << seconds << " seconds\n";
}

static void ExecuteMedusasWithScheduler(
	const std::vector<std::unique_ptr<TaskProxy>>& tasks,
	FileNode* fileTreeRoot,
	size_t inputCount,
	size_t outputCount)
{
	std::vector<TaskProxy*> rawTasks;
	rawTasks.reserve(tasks.size());
	for(const auto& t : tasks)
		rawTasks.push_back(t.get());

	ConnectImplicitProducers(fileTreeRoot);

	TaskScheduler scheduler(0 /*unlimited*/);
	ConnectDynamicInputsForScheduler(rawTasks, scheduler.rootTask());

	std::cout << "Executing medusa chain with TaskScheduler\n";
	hi_res_timer timer;
	scheduler.startExecutionAndWait();
	double seconds = timer.elapsed();
	std::cout << "Finished medusa execution in " << seconds << " seconds\n";
}


int main(int argc, const char* argv[])
{
	size_t totalInputCount = 0;
	size_t totalOutputCount = 0;

#if TEST_RECURSIVE
	{
		printf("Single-threaded recursive medusa algorithm\n\n");
		FileNode* fileTreeRoot = CreateFileTreeRoot();

		auto testTasks = GenerateTestTasks<MedusaTaskProxy>(
			fileTreeRoot,
			100000, // task_count
			20,     // max_static_input_count
			20,     // max_dynamic_input_count
			20,     // max_output_count
			&totalInputCount,
			&totalOutputCount);

		ExecuteMedusasRecursively(testTasks, fileTreeRoot, totalInputCount, totalOutputCount);

		{
			hi_res_timer timer;
			testTasks.clear();
			double seconds = timer.elapsed();
			std::cout << "Releasing all generated MedusaTaskProxy nodes took " << seconds << " seconds\n";
		}

		DeleteFileTree(fileTreeRoot);
		printf("\n\n--------------------------------\n");
	}
#endif // TEST_RECURSIVE

	{
		FileNode* fileTreeRoot = CreateFileTreeRoot();
		printf("Concurrent medusa algorithm with TaskScheduler\n\n");

		auto scheduleTasks = GenerateTestTasks<TaskProxy>(
			fileTreeRoot,
			100000, // task_count
			20,     // max_static_input_count
			20,     // max_dynamic_input_count
			20,     // max_output_count
			&totalInputCount,
			&totalOutputCount);

		ExecuteMedusasWithScheduler(scheduleTasks, fileTreeRoot, totalInputCount, totalOutputCount);

		{
			hi_res_timer timer;
			scheduleTasks.clear();
			double seconds = timer.elapsed();
			std::cout << "Releasing all generated TaskProxy nodes took " << seconds << " seconds\n";
		}

		DeleteFileTree(fileTreeRoot);
	}

	return 0;
}
