#ifndef _LogStream_h_
#define _LogStream_h_

#include <string>

// Global references
extern FILE *gLogOut;
extern FILE *gLogErr;

int open_stdout_stream(const std::string& path);
int open_stderr_stream(const std::string& path);
void close_stdout_stream();
void close_stderr_stream();
[[noreturn]] void safe_exit(int status);

// The thread-safe logging wrapper
void LogError(const char *format, ...);

#endif /* _LogStream_h_ */
