#include "LogStream.h"
#include <stdlib.h>

FILE *gLogOut = NULL;
FILE *gLogErr = NULL;

//executed on process start before main:
__attribute__((constructor))
static void InitLogStream(void)
{
	gLogOut = stdout;
	gLogErr = stderr;
}

int
open_stdout_stream(const char * restrict path)
{
	if(path == NULL)
		return EXIT_FAILURE;

	gLogOut = fopen(path, "we"); // "e" flag so the forked processes don't keep it open
	if(gLogOut == NULL)
	{
		fprintf(stderr, "An error occurred while opening out log file for writing: %s\n", path);
		return EXIT_FAILURE;
	}
	return EXIT_SUCCESS;
}

int
open_stderr_stream(const char * restrict path)
{
	if(path == NULL)
		return EXIT_FAILURE;

	gLogErr = fopen(path, "we"); // "e" flag so the forked processes don't keep it open
	if(gLogErr == NULL)
	{
		fprintf(stderr, "An error occurred while opening err log file for writing: %s\n", path);
		return EXIT_FAILURE;
	}
	return EXIT_SUCCESS;
}

void
close_stdout_stream(void)
{
	// fclose calls fflush before closing so no need to do it explicitly
	if(gLogOut != stdout)
	{
		fclose(gLogOut);
		gLogOut = stdout; //just in case some stray thread still prints
	}
}

void
close_stderr_stream(void)
{
	// fclose calls fflush before closing so no need to do it explicitly
	if(gLogErr != stderr)
	{
		fclose(gLogErr);
		gLogErr = stderr; //just in case some stray thread still prints
	}
}

void safe_exit(int status)
{
	// if we have custom stdout and/or stderr files opened, close them now
	close_stdout_stream();
	close_stderr_stream();
	exit(status);
}
