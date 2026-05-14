#include "LogStream.h"
#include <stdlib.h>
#include <mutex>

FILE *gLogOut = nullptr;
FILE *gLogErr = nullptr;

// Protects stream reassignment operations from cross-thread initialization races
static std::mutex sStreamMutex;

// Explicit mutex dedicated to standalone logging channels
static std::mutex sLogMutex;

//executed on process start before main:
__attribute__((constructor))
static void InitLogStream(void)
{
	gLogOut = stdout;
	gLogErr = stderr;
}

void LogError(const char *format, ...)
{
    std::lock_guard<std::mutex> lock(sLogMutex);
    
    va_list args;
    va_start(args, format);
    vfprintf(gLogErr, format, args);
    va_end(args);
    
    // Ensure the message is flushed immediately through the pipe
    fflush(gLogErr);
}


int open_stdout_stream(const std::string& path)
{
    if (path.empty())
        return EXIT_FAILURE;

    std::lock_guard<std::mutex> lock(sStreamMutex);
	gLogOut = fopen(path.c_str(), "we"); // "e" flag so the forked processes don't keep it open
	if(gLogOut == NULL)
	{
		fprintf(stderr, "An error occurred while opening out log file for writing: %s\n", path.c_str());
		return EXIT_FAILURE;
	}
	return EXIT_SUCCESS;
}

int open_stderr_stream(const std::string& path)
{
    if (path.empty())
        return EXIT_FAILURE;

    std::lock_guard<std::mutex> lock(sStreamMutex);
	gLogErr = fopen(path.c_str(), "we"); // "e" flag so the forked processes don't keep it open
	if(gLogErr == NULL)
	{
		fprintf(stderr, "An error occurred while opening err log file for writing: %s\n", path.c_str());
		return EXIT_FAILURE;
	}
	return EXIT_SUCCESS;
}

void close_stdout_stream()
{
    std::lock_guard<std::mutex> lock(sStreamMutex);
	// fclose calls fflush before closing so no need to do it explicitly
	if(gLogOut != stdout)
	{
		fclose(gLogOut);
		gLogOut = stdout; //just in case some stray thread still prints
	}
}

void close_stderr_stream()
{
    std::lock_guard<std::mutex> lock(sStreamMutex);
	// fclose calls fflush before closing so no need to do it explicitly
	if(gLogErr != stderr)
	{
		fclose(gLogErr);
		gLogErr = stderr; //just in case some stray thread still prints
	}
}

[[noreturn]] void safe_exit(int status)
{
    close_stdout_stream();
    close_stderr_stream();
    std::exit(status);
}
