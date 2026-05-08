#import <Foundation/Foundation.h>
#import "ReplayAction.h"
#import "ReplayActionPrivate.h"
#include <sys/stat.h>
#include <time.h>
#include <cerrno>

static void format_permissions(mode_t mode, char out[11])
{
	if      (S_ISREG(mode))  out[0] = '-';
	else if (S_ISDIR(mode))  out[0] = 'd';
	else if (S_ISLNK(mode))  out[0] = 'l';
	else if (S_ISCHR(mode))  out[0] = 'c';
	else if (S_ISBLK(mode))  out[0] = 'b';
	else if (S_ISFIFO(mode)) out[0] = 'p';
	else if (S_ISSOCK(mode)) out[0] = 's';
	else                     out[0] = '?';
	out[1] = (mode & S_IRUSR) ? 'r' : '-';
	out[2] = (mode & S_IWUSR) ? 'w' : '-';
	out[3] = (mode & S_IXUSR) ? ((mode & S_ISUID) ? 's' : 'x') : ((mode & S_ISUID) ? 'S' : '-');
	out[4] = (mode & S_IRGRP) ? 'r' : '-';
	out[5] = (mode & S_IWGRP) ? 'w' : '-';
	out[6] = (mode & S_IXGRP) ? ((mode & S_ISGID) ? 's' : 'x') : ((mode & S_ISGID) ? 'S' : '-');
	out[7] = (mode & S_IROTH) ? 'r' : '-';
	out[8] = (mode & S_IWOTH) ? 'w' : '-';
	out[9] = (mode & S_IXOTH) ? ((mode & S_ISVTX) ? 't' : 'x') : ((mode & S_ISVTX) ? 'T' : '-');
	out[10] = '\0';
}

static void format_iso8601(time_t t, char out[21])
{
	struct tm tm_utc;
	gmtime_r(&t, &tm_utc);
	strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &tm_utc);
}

bool
GetFileInfo(const char *path, ReplayContext *context, ActionContext *actionContext)
{
	if(context->stopOnError && context->lastError.error != nil)
		return false;

	if(context->verbose || context->dryRun)
	{
		NSString *stdoutStr = [NSString stringWithFormat:@"[info]\t%s\n", path];
		PrintToStdOut(context, stdoutStr, actionContext->index);
	}
	else
	{
		ActionWithNoOutput(context, actionContext->index);
	}

	actionContext->index++;

	if(context->dryRun)
	{
		ActionWithNoOutput(context, actionContext->index);
		return true;
	}

	struct stat st;
	if(lstat(path, &st) != 0)
	{
		int err = errno;
		NSString *errStr = [NSString stringWithFormat:@"error: failed to stat \"%s\": %s\n", path, strerror(err)];
		PrintToStdErr(context, errStr);
		NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: errStr };
		context->lastError.error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:userInfo];
		ActionWithNoOutput(context, actionContext->index);
		return false;
	}

	char perms[11];
	format_permissions(st.st_mode, perms);

	char created[21];
	time_t birthtime = st.st_birthtimespec.tv_sec;
	if(birthtime == 0)
		birthtime = st.st_ctimespec.tv_sec;
	format_iso8601(birthtime, created);

	char modified[21];
	format_iso8601(st.st_mtimespec.tv_sec, modified);

	const char *typeStr;
	if      (S_ISREG(st.st_mode))  typeStr = "file";
	else if (S_ISDIR(st.st_mode))  typeStr = "directory";
	else if (S_ISLNK(st.st_mode))  typeStr = "symlink";
	else                            typeStr = "other";

	NSString *output = [NSString stringWithFormat:
		@"[info:%s]\nsize: %lld\ncreated: %s\nmodified: %s\ntype: %s\npermissions: %s\n",
		path,
		(long long)st.st_size,
		created,
		modified,
		typeStr,
		perms];
	PrintToStdOut(context, output, actionContext->index);
	return true;
}
