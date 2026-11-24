#include "LogStream.h"
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <cstdarg>
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


// Opens a log file for writing, truncating it. Not through a symbolic link: a link at
// the log path, planted by someone who can write its folder, would make this process
// write (and truncate) a file of its choice. Close-on-exec, so the processes replay
// starts do not keep it open. Returns nullptr with errno set on failure.
// Paths in /dev and /proc/self/fd are the exception: /dev/stdout, /dev/stderr and
// /dev/fd/N are links (into /proc/self/fd on Linux), and only the system can put a
// link there.
static FILE *open_log_file(const std::string& path)
{
    bool system_link = (path.compare(0, 5, "/dev/") == 0) || (path.compare(0, 14, "/proc/self/fd/") == 0);
    int flags = O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | (system_link ? 0 : O_NOFOLLOW);
    int fd = open(path.c_str(), flags, 0666);
    if (fd < 0)
        return nullptr;
    FILE *file = fdopen(fd, "w");
    if (file == nullptr)
    {
        int saved = errno;
        close(fd);
        errno = saved;
    }
    return file;
}

static void report_log_open_failure(const char *which, const std::string& path)
{
    int error = errno;
    fprintf(stderr, "An error occurred while opening %s log file for writing: %s: %s%s\n", which, path.c_str(),
            strerror(error), (error == ELOOP) ? " (log files are not opened through a symbolic link)" : "");
}

int open_stdout_stream(const std::string& path)
{
    if (path.empty())
        return EXIT_FAILURE;

    std::lock_guard<std::mutex> lock(sStreamMutex);
	FILE *file = open_log_file(path);
	if(file == nullptr)
	{
		report_log_open_failure("out", path);
		return EXIT_FAILURE;
	}
	if(gLogOut != stdout)
		fclose(gLogOut);
	gLogOut = file;
	return EXIT_SUCCESS;
}

int open_stderr_stream(const std::string& path)
{
    if (path.empty())
        return EXIT_FAILURE;

    std::lock_guard<std::mutex> lock(sStreamMutex);
	FILE *file = open_log_file(path);
	if(file == nullptr)
	{
		report_log_open_failure("err", path);
		return EXIT_FAILURE;
	}
	if(gLogErr != stderr)
		fclose(gLogErr);
	gLogErr = file;
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
