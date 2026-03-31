#include <stdio.h>

#ifndef _LogStream_h_
#define _LogStream_h_

#ifdef __cplusplus
extern "C" {
#endif

// global stream pointers used for fprintf
// in default implementation they are
// just stdout and stderr respectively

extern FILE *gLogOut;
extern FILE *gLogErr;

// Open the file for writing, creating new as needed, overwriting old content.
// "path" param must be non-null
// The functions return EXIT_SUCCESS or EXIT_FAILURE with the intent
// that the client exits immediately on failure

int open_stdout_stream(const char *path);
int open_stderr_stream(const char *path);

void close_stdout_stream(void);
void close_stderr_stream(void);

void safe_exit(int status) __attribute__((__noreturn__));

#ifdef __cplusplus
}
#endif

#endif /* _LogStream_h_ */
