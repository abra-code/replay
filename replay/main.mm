//
//  main.m
//  replay
//
//  Created by Tomasz Kukielka on 8/8/20.
//  Copyright © 2020 Tomasz Kukielka. All rights reserved.
//

#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <getopt.h>
#import "ReplayAction.h"
#include "OutputSerializer.h"
#import "TaskProxy.h"
#import "ReplayTask.h"
#import "SerialDispatch.h"
#import "ConcurrentDispatchWithNoDependency.h"
#import "ActionStream.h"
#import "ReplayServer.h"
#include "replay_version.h"
#include "SandboxProfile.h"
#include "PlaylistSandboxPaths.h"
#include "FileHelpers.h"
#include "MCPServer.h"
#include "EnvVarExpand.h"
#include "PlaylistDoc.h"

#include <limits.h>


#if DEBUG
	#define TRACE 0
#endif

// Long-only options use values >= 256 so they don't collide with short opts.
enum
{
	kOptSandbox = 256,
	kOptSandboxProfile,
	kOptAllowRead,
	kOptAllowWrite,
	kOptDenyNetwork,
	kOptMCPServer,
};

static struct option sLongOptions[] =
{
	{"verbose",				no_argument,		NULL, 'v'},
	{"dry-run",				no_argument,		NULL, 'n'},
	{"serial",				no_argument,		NULL, 's'},
	{"max-tasks",			required_argument,	NULL, 't'},
	{"no-dependency",		no_argument,		NULL, 'p'},
	{"playlist-key",		required_argument,	NULL, 'k'},
	{"stop-on-error",		no_argument,		NULL, 'e'},
	{"force",				no_argument,		NULL, 'f'},
	{"ordered-output",		no_argument,		NULL, 'o'},
	{"start-server",		required_argument,	NULL, 'r'},
	{"stdout",				required_argument,	NULL, 'l'},
	{"stderr",				required_argument,	NULL, 'm'},
	{"sandbox",				no_argument,			NULL, kOptSandbox},
	{"sandbox-profile",		required_argument,	NULL, kOptSandboxProfile},
	{"allow-read",			required_argument,	NULL, kOptAllowRead},
	{"allow-write",			required_argument,	NULL, kOptAllowWrite},
	{"deny-network",		no_argument,			NULL, kOptDenyNetwork},
	{"mcp-server",			no_argument,			NULL, kOptMCPServer},
	{"version",				no_argument,		NULL, 'V'},
	{"help",				no_argument,		NULL, 'h'},
	{NULL, 					0,					NULL,  0 }
};


static void
DisplayHelp(void)
{
	printf(
		"\n"
		"\n"
		"replay -- execute a declarative script of actions, aka a playlist\n"
		"\n"
		"Usage:\n"
		"\n"
		"  replay [options] [playlist_file.json|plist]\n"
		"\n"
		"Options:\n"
		"\n"
		"  -k, --playlist-key KEY   Use a key in root dictionary of the playlist file for action steps array.\n"
		"                     If absent, the playlist file root container is assumed to be an array of action steps.\n"
		"                     The key may be specified multiple times to execute more than one playlist in the file.\n"
		"  -s, --serial       Execute actions serially in the order specified in the playlist (slow).\n"
		"                     Default behavior is to execute actions concurrently, if possible, after dependency analysis (fast).\n"
		"  -p, --no-dependency   An option for concurrent execution to skip dependency analysis. Actions must be independent.\n"
		"  -o, --ordered-output   In simple concurrent execution mode preserve the order of printed task outputs as specified\n"
		"                     in the playlist. The tasks are still executed concurrently without order guarantee\n"
		"                     but printing is ordered. Ignored in serial execution and concurrent execution with dependencies.\n"
		"  -t, --max-tasks NUMBER   Maximum number of concurrently executed actions. Default is 0, which is treated as unbound.\n"
		"                     Limiting the number of concurrent operations may sometimes result in faster execution.\n"
		"                     With intensive file I/O tasks a low number like 4 may yield the best performance.\n"
		"                     For CPU intensive tasks you may use logical CPU core count (or a multiplier) as obtained by:\n"
		"                     sysctl -n hw.ncpu\n"
		"  -e, --stop-on-error   Stop executing the remaining playlist actions on first error.\n"
		"  -f, --force        If the file operation fails, delete destination and try again.\n"
		"  -n, --dry-run      Show a log of actions which would be performed without running them.\n"
		"  -v, --verbose      Show a log of actions while they are executed.\n"
		"  -r, --start-server BATCH_NAME   Start server and listen for dispatch requests. \"BATCH_NAME\" must be a unique name\n"
		"                     identifying a group of actions to be executed concurrently. Subsequent requests to add actions\n"
		"                     with \"dispatch\" tool must refer to the same name. \"replay\" server listens to request messages\n"
		"                     sent by \"dispatch\". If the server is not running for given batch name, the first request to add\n"
		"                     an action starts \"replay\" in server mode. Therefore starting the server manually is not required\n"
		"                     but it is possible if needed.\n"
		"  -l, --stdout PATH  log standard output to provided file path.\n"
		"  -m, --stderr PATH  log standard error to provided file path.\n"
		"  --sandbox          Enable hard sandbox. When used with a playlist file (not stdin), replay\n"
		"                     auto-discovers declared paths from the playlist and adds them to the policy.\n"
		"                     Combine with --allow-read, --allow-write, --sandbox-profile for additional paths.\n"
		"                     Tool paths in \"execute\" actions must be absolute (e.g. /usr/bin/python3),\n"
		"                     not bare names — $PATH lookup happens after the sandbox is active.\n"
		"                     Violations return EPERM to the caller;\n"
		"                     To discover path requirements, use sandbox/sandbox-discover.py\n"
        "                     To stream violations in real time run:\n"
		"                       log stream --style compact --predicate 'subsystem == \"com.apple.sandbox\" || sender == \"Sandbox\"'\n"
		"  --sandbox-profile FILE  JSON file with full sandbox spec; merged with --allow-read/--allow-write.\n"
		"                     Implicitly enables --sandbox.\n"
		"  --allow-read PATH    Allow read-only access to PATH (repeatable). Implicitly enables --sandbox.\n"
		"  --allow-write PATH   Allow read+write access to PATH (repeatable). Implicitly enables --sandbox.\n"
		"  --deny-network       With sandbox active, deny outbound network (allowed by default).\n"
		"  --mcp-server             Start an MCP (Model Context Protocol) stdio server.\n"
		"                     Use --allow-read PATH for read-only dirs and --allow-write PATH for\n"
		"                     read-write dirs (repeatable). Both flags imply --sandbox.\n"
		"                     Implements the standard MCP filesystem tool set plus extended tools:\n"
		"                     read_file, read_multiple_files, write_file, edit_file (with regex),\n"
		"                     create_directory, list_directory, directory_tree, move_file,\n"
		"                     delete_file, search_files, get_file_info,\n"
		"                     list_allowed_directories, glob_search.\n"
		"  -V, --version      Display version.\n"
		"  -h, --help         Display this help.\n"
		"\n"
	);

	printf(
		"Playlist format:\n"
		"\n"
		"  Playlists can be composed in plist or JSON files.\n"
		"  In the usual form the root container of a plist or JSON file is a dictionary,\n"
		"  where you can put one or more playlists with unique keys.\n"
		"  A playlist is an array of action steps.\n"
		"  Each step is a dictionary with action type and parameters. See below for actions and examples.\n"
		"  If you don't specify the playlist key, the root container is expected to be an array of action steps.\n"
		"  More than one playlist may be present in a root dictionary. For example, you may want preparation steps\n"
		"  in one playlist to be executed by \"replay\" invocation with --serial option\n"
		"  and have another concurrent playlist with the bulk of work executed by a second \"replay\" invocation\n"
		"\n"
	);

	printf(
		"Environment variables expansion:\n"
		"\n"
		"  Environment variables in form of ${VARIABLE} are expanded in all paths.\n"
		"  New file content may also contain environment variables in its body (with an option to turn off expansion).\n"
		"  Missing environment variables or malformed text is considered an error and the action will not be executed.\n"
		"  It is easy to make a mistake and allowing evironment variables resolved to empty would result in invalid paths,\n"
		"  potentially leading to destructive file operations.\n"
		"\n"
	);

	printf(
		"Dependency analysis:\n"
		"\n"
		"  In default execution mode (without --serial or --no-dependency option) \"replay\" performs dependency analysis\n"
		"  and constructs an execution graph based on files consumed and produced by actions.\n"
		"  If a file produced by action A is needed by action B, action B will not be executed until action A is finished.\n"
		"  For example: if your playlist contains an action to create a directory and other actions write files\n"
		"  into this directory, all these file actions will wait for directory creation to be finished and then they will\n"
		"  be executed concurrently if otherwise independent from each other.\n"
		"  Concurrent execution imposes a couple of rules on actions:\n"
		"  1. No two actions may produce the same output. With concurrent execution this would produce undeterministic results\n"
		"     depending on which action happened to run first or fail if they accessed the same file for writing concurrently.\n"
		"     \"replay\" will not run any actions when this condition is detected during dependency analysis.\n"
		"  2. Action dependencies must not create a cycle. In other words the dependency graph must be a proper DAG.\n"
		"     An example cycle is one action copying file A to B and another action copying file B to A.\n"
		"     Replay algorithm tracks the number of unsatisifed dependencies for each action. When the number drops to zero,\n"
		"     the action is dispatched for execution. For actions in a cycle that number never drops to zero and they can\n"
		"     never be dispatched. After all dispatched tasks are done \"replay\" verifies all actions in the playlist\n"
		"     were executed and reports a failure if they were not, listing the ones which were skipped.\n"
		"  3. Deletion and creation of the same file or directory in one playlist will result in creation first and\n"
		"     deletion second because the deletion consumes the output of creation. If deletion is a required preparation step\n"
		"     it should be executed in a separate playlist before the main tasks are scheduled. You may pass --playlist-key\n"
		"     multiple times as a parameter and the playlists will be executed one after another in the order specified.\n"
		"  4. Moving or deleting an item makes it unusable for other actions at the original path. Such actions are exclusive\n"
		"     consumers of given input paths and cannot share their inputs with other actions. Producing additional items under\n"
		"     such exclusive input paths is also not allowed. \"replay\" will report an error during dependency analysis\n"
		"     and will not execute an action graph with exclusive input violations.\n"
		"\n"
	);

	printf(
		"Actions and parameters:\n"
		"\n"
		"  clone       Copy file(s) from one location to another. Cloning is supported on APFS volumes.\n"
		"              Source and destination for this action can be specified in 2 ways.\n"
		"              One to one:\n"
		"    from      Source item path.\n"
		"    to        Destination item path.\n"
		"              Or many items to destination directory:\n"
		"    items     Array of source item paths.\n"
		"    destination directory   Path to output folder.\n"
		"  copy        Synonym for clone. Functionally identical.\n"
		"  move        Move a file or directory.\n"
		"              Source and destination for this action can be specified the same way as for \"clone\".\n"
		"              Source path(s) are invalidated by \"move\" so they are marked as exclusive in concurrent execution.\n"
		"  hardlink    Create a hardlink to source file.\n"
		"              Source and destination for this action can be specified the same way as for \"clone\".\n"
		"  symlink     Create a symlink pointing to original file.\n"
		"              Source and destination for this action can be specified the same way as for \"clone\".\n"
      	"    validate   Bool value to indicate whether to check for the existence of source file. Default is true.\n"
      	"              It is usually a mistake if you try to create a symlink to nonexistent file,\n"
      	"              that is why \"validate\" is true by default but it is possible to create a dangling symlink.\n"
      	"              If you know what you are doing and really want that behavior, set \"validate\" to false.\n"
		"  create      Create a file or a directory.\n"
      	"              You can create either a file with optional content or a directory but not both in one action step.\n"
      	"    file      New file path (only for files).\n"
      	"    content   New file content string (only for files).\n"
      	"    raw       Bool value to indicate whether environment variables should be expanded or not in content text.\n"
      	"              Default value is \"false\", meaning that environment variables are expanded.\n"
      	"              Pass \"true\" if you want to write a script with some ${VARIABLE} usage\n"
		"    blob      Base64-encoded binary content. Mutually exclusive with \"content\".\n"
		"              When present, the decoded bytes are written as-is (no environment variable expansion).\n"
      	"    directory   New directory path. All directories leading to the deepest one are created if they don't exist.\n"
		"  delete      Delete a file or directory (with its content).\n"
		"              CAUTION: There is no warning or user confirmation requested before deletion.\n"
		"    items     Array of item paths to delete (files or directories with their content).\n"
		"              Item path(s) are invalidated by \"delete\" so they are marked as exclusive in concurrent execution.\n"
		"  read        Read one or more files and print their contents to stdout.\n"
		"    items     Array of file paths to read.\n"
		"              Valid UTF-8 files are printed as:    [text:path]<newline><content><newline>\n"
		"              Binary (non-UTF-8) files are printed as: [blob:path]<newline><base64><newline>\n"
		"  list        List the immediate children of a directory.\n"
		"    directory   Path to the directory to list.\n"
		"              Output format: [list:path]<newline> followed by one entry per line:\n"
		"              [FILE] name  or  [DIR] name, sorted alphabetically.\n"
		"  tree        Recursively list directory contents as JSON.\n"
		"    directory   Path to the root directory.\n"
		"    depth     Maximum recursion depth (default 5). Set to 0 to get only the root node.\n"
		"              Output format: [tree:path]<newline><json><newline>\n"
		"              JSON schema: {\"name\": str, \"type\": \"directory\"|\"file\",\n"
		"                            \"children\": [...]}  (children present only for directories)\n"
		"  info        Return metadata for a file or directory path.\n"
		"    path      Path to query.\n"
		"              Output format: [info:path]<newline><json><newline>\n"
		"              JSON schema: {\"path\": str, \"type\": \"file\"|\"directory\"|\"symlink\",\n"
		"                            \"size\": int, \"modified\": float (unix timestamp)}\n"
		"  glob        Search for files matching glob patterns under a root directory.\n"
		"    root      Root directory to search from.\n"
		"    glob      Array of glob patterns relative to root (e.g. \"**/*.swift\").\n"
		"              Patterns starting with \"!\" are exclusions and remove matches from the result.\n"
		"    exclude   Array of paths or patterns to exclude from traversal (optional).\n"
		"    max       Maximum number of results to return (optional, default unlimited).\n"
		"              Output format: one absolute file path per line, preceded by [glob] header.\n"
		"  edit        Search-and-replace text or regex patterns in one or more files. Written atomically.\n"
		"    items     Array of file paths and/or glob patterns (required). Each entry is independent:\n"
		"              concrete paths each produce their own task (may run in parallel);\n"
		"              glob patterns each produce one task that expands and edits all matches at runtime.\n"
		"              Error if a glob pattern matches no files.\n"
		"    edits     Array of edit operations applied in order, each a dict with:\n"
		"      oldText   Text or pattern to search for (required).\n"
		"      newText   Replacement text. In regex mode \\\\1..\\\\9 are back-references. Default \"\" (delete).\n"
		"      limit     Max replacements per operation. Default 1. Set to 0 for unlimited.\n"
		"      regex     Bool. Treat oldText as a POSIX ERE regex pattern. Default false.\n"
		"      case-insensitive   Bool. Case-insensitive matching for literal and regex modes. Default false.\n"
		"    dry-run   Bool. Show the edit plan without writing the file. Default false.\n"
		"              In dry-run mode output is: [edit-dry-run:path]<newline> followed by one line per\n"
		"              operation: \"oldText\" -> \"newText\" (limit=N [regex])\n"
		"  execute     Run an executable as a child process.\n"
		"    tool      Full path to a tool to execute.\n"
		"    arguments   Array of arguments to pass to the tool (optional).\n"
		"    inputs    Array of file paths read by the tool during execution (optional).\n"
		"    exclusive inputs    Array of file paths invalidated (items deleted or moved) by the tool (rare, optional).\n"
		"    outputs   Array of file paths writen by the tool during execution (optional).\n"
		"    stdout    Bool value to indicate whether the output of the tool should be printed to stdout (optional).\n"
		"              Default value is \"true\", indicating the output from child process is printed to stdout.\n"
		"  echo        Print a string to stdout.\n"
		"    text      The text to print.\n"
      	"    raw       Bool value to indicate whether environment variable expansion should be suppressed. Default is \"false\".\n"
      	"    newline   Bool value to indicate whether the output string should be followed by newline. Default is \"true\".\n"
		"\n"
	);


	printf(
		"Streaming actions through stdin pipe:\n"
		"\n"
		"\"replay\" allows sending a stream of actions via stdin when the playlist file is not specified.\n"
		"Actions may be executed serially or concurrently but without dependency analysis.\n"
		"Dependency analysis requires a complete set of actions to create a graph, while streaming\n"
		"starts execution immediately as the action requests arrive.\n"
		"Concurrent execution is default, which does not guarantee the order of actions but an option:\n"
		"--ordered-output has been added to ensure the output order is the same as action scheduling order.\n"
		"For example, while streaming actions A, B, C in that order, the execution may happen like this: A, C, B\n"
		"but the printed output will still be preserved as A, B, C. This implies that that output of C\n"
		"will be delayed if B is taking long to finish.\n"
		"\n"
		"The format of streamed/piped actions is one action per line (not plist or json!), as follows:\n"
		"- ignore whitespace characters at the beginning of the line, if any\n"
		"- action and options come first in square brackets, e.g.: [clone], [move], [delete], [create file] [create directory]\n"
		"  some options can be added as key=value as described in \"Actions and parmeters\" section above with examples below\n"
		"- the first character following the closing square bracket ']' is used as a field delimiter for the parameters to the action\n"
		"- variable length parameters are following, separated by the same field separator, specific to given action\n"

		"Param interpretation per action\n"
		"(examples use \"tab\" as a separator)\n"
		"- [clone], [move], [hardlink], [symlink] allow only simple from-to specification,\n"
		"  with first param interpretted as \"from\" and second as \"to\" e.g.:\n"
		"[clone]	/path/to/src/file.txt	/path/to/dest/file.txt\n"
		"[symlink validate=false]	/path/to/src/file.txt	/path/to/symlink/file.txt\n"
		"- [delete] is followed by one or many paths to items, e.g.:\n"
		"[delete]	/path/to/delete/file1.txt	/path/to/delete/file2.txt\n"
		"- [read] is followed by one or many file paths to read, e.g.:\n"
		"[read]	/path/to/read/file1.txt	/path/to/read/file2.bin\n"
		"- [list] lists immediate children of a directory:\n"
		"[list]	/path/to/directory\n"
		"- [tree] recursively lists a directory as JSON (optional depth modifier, default 5):\n"
		"[tree]	/path/to/directory\n"
		"[tree depth=3]	/path/to/directory\n"
		"- [info] requires a single path to query file metadata:\n"
		"[info]	/path/to/file.txt\n"
		"- [glob] requires root directory and one or more glob patterns (comma-separated):\n"
		"[glob]	/path/to/search	*.swift\n"
		"- [create] has 2 variants: [create file] and [create directory].\n"
		"  If \"file\" or \"directory\" option is not specified, it falls back to \"file\"\n"
		"  A. [create file] requires path followed by optional content, e.g.:\n"
		"[create file]	/path/to/create/file.txt	Created by replay!\n"
		"[create file raw=true]	/path/to/file.txt	Do not expand environment variables like ${HOME}\n"
		"     [create file blob=true] writes binary content supplied as base64, e.g.:\n"
		"[create file blob=true]	/path/to/create/file.bin	iVBORw0KGgo=\n"
		"  B. [create directory] requires just a single path, e.g.:\n"
		"[create directory]	/path/to/create/directory\n"
		"- [edit] requires a file path (or glob pattern), oldText, and optional newText as tab-separated fields.\n"
		"  When a glob pattern is used as the file path it is expanded at runtime; all matches are edited.\n"
		"  For multiple independent paths or patterns, send one [edit] line per path.\n"
		"  Modifiers: limit=N (default 1, 0=unlimited), regex=true, case-insensitive=true, dry-run=true\n"
		"[edit]	/path/to/file.txt	old text	new text\n"
		"[edit]	/path/to/file.txt	old text\n"
		"[edit regex=true limit=0]	/path/to/file.txt	([a-z]+)_v1	\\1_v2\n"
		"[edit case-insensitive=true]	/path/to/file.txt	TODO	DONE\n"
		"[edit]	/path/to/src/*.cpp	OLD_API	NEW_API\n"
		"- [execute] requires tool path and may have optional parameters separated with the same delimiter (not space delimited!), e.g.:\n"
		"[execute]	/bin/echo	Hello from replay!\n"
		"[execute stdout=false]	/bin/echo	This will not be printed\n"
		"  The following example uses a different separator: \"+\" to explicitly show delimited parameters:\n"
		"[execute]+/bin/sh+-c+/bin/ls ${HOME} | /usr/bin/grep \".txt\"\n"
		"- [echo] requires one string after separator. Supported modifiers are raw=true and newline=false\n"
		"\n"
	);

	printf(
		"Example JSON playlist:\n"
		"\n"
		"{\n"
		"  \"Shepherd Playlist\": [\n"
		"    {\n"
		"      \"action\": \"create\",\n"
		"      \"directory\": \"${HOME}/Pen\",\n"
		"    },\n"
		"    {\n"
		"      \"action\": \"clone\",\n"
		"      \"from\": \"${HOME}/sheep.txt\",\n"
		"      \"to\": \"${HOME}/Pen/clone.txt\",\n"
		"    },\n"
		"    {\n"
		"      \"action\": \"move\",\n"
		"      \"items\": [\n"
		"          \"${HOME}/sheep1.txt\",\n"
		"          \"${HOME}/sheep2.txt\",\n"
		"          \"${HOME}/sheep3.txt\",\n"
		"          ],\n"
		"      \"destination directory\": \"${HOME}/Pen\",\n"
		"    },\n"
		"    {\n"
		"      \"action\": \"delete\",\n"
		"      \"items\": [\n"
		"          \"${HOME}/Pen/clone.txt\",\n"
		"          ],\n"
		"    },\n"
		"  ],\n"
		"}\n"
		"\n"
	);
	
	printf(
		"Example plist playlist:\n"
		"\n"
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
		"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
		"<plist version=\"1.0\">\n"
		"<dict>\n"
		"    <key>Shepherd Playlist</key>\n"
		"    <array>\n"
		"        <dict>\n"
		"            <key>action</key>\n"
		"            <string>create</string>\n"
		"            <key>directory</key>\n"
		"            <string>${HOME}/Pen</string>\n"
		"        </dict>\n"
		"        <dict>\n"
		"            <key>action</key>\n"
		"            <string>clone</string>\n"
		"            <key>from</key>\n"
		"            <string>${HOME}/sheep.txt</string>\n"
		"            <key>to</key>\n"
		"            <string>${HOME}/Pen/clone.txt</string>\n"
		"        </dict>\n"
		"        <dict>\n"
		"            <key>action</key>\n"
		"            <string>move</string>\n"
		"            <key>items</key>\n"
		"            <array>\n"
		"                <string>${HOME}/sheep1.txt</string>\n"
		"                <string>${HOME}/sheep2.txt</string>\n"
		"                <string>${HOME}/sheep3.txt</string>\n"
		"            </array>\n"
		"            <key>destination directory</key>\n"
		"            <string>${HOME}/Pen</string>\n"
		"        </dict>\n"
		"        <dict>\n"
		"            <key>action</key>\n"
		"            <string>delete</string>\n"
		"            <key>items</key>\n"
		"            <array>\n"
		"                <string>${HOME}/Pen/clone.txt</string>\n"
		"            </array>\n"
		"        </dict>\n"
		"    </array>\n"
		"</dict>\n"
		"</plist>\n"
		"\n"
	);

	printf(
		"Example execution:\n"
		"\n"
		"  replay --dry-run --playlist-key \"Shepherd Playlist\" shepherd.plist\n"
		"\n"
		"In the above example playlist some output files are inputs to later actions.\n"
		"The dependency analysis will create an execution graph to run dependent actions after the required outputs are produced.\n"
		"\n"
	);

	printf(
		"Sandbox profile JSON schema (--sandbox-profile FILE):\n"
		"\n"
		"  All fields are optional. Defaults shown.\n"
		"\n"
		"  {\n"
		"    \"import_baseline\": true,        // include bsd.sb (covers dyld, /tmp reads, Mach IPC)\n"
		"    \"read_only\":  [\"/path\", ...],   // recursive file-read* access\n"
		"    \"read_write\": [\"/path\", ...],   // recursive file-read* + file-write* access\n"
		"    \"allow_network\": true,           // set false to deny all network connections\n"
		"    \"allow_exec\":    true,           // set false to deny process-exec*\n"
		"    \"allow_fork\":    true,           // set false to deny process-fork\n"
		"    \"extra_rules\": [\"(allow ...)\"]  // raw SBPL rules appended verbatim\n"
		"  }\n"
		"\n"
		"  System binaries (/bin, /usr/bin) do not need an explicit read_only entry;\n"
		"  process-exec* covers launching them and bsd.sb covers their system dylibs.\n"
		"  Third-party tools (Homebrew, Python frameworks) need their prefix in read_only\n"
		"  because dyld must open their framework or library files at startup.\n"
		"\n"
	);

	printf(
		"See also:\n"
		"\n"
		"  dispatch --help\n"
		"\n"
		"\n"
	);
}

static void
ProcessPlaylist(const std::vector<ActionStep>& playlist, ReplayContext *context)
{
	if(context->concurrent)
	{
		context->actionCounter = -1;

		if(context->analyzeDependencies)
		{
			// if someone set this as a param, we need to ignore it when executing a graph of tasks
			context->orderedOutput = false;
			DispatchTasksConcurrentlyWithDependencyAnalysis(playlist, context);
		}
		else
		{
			DispatchTasksConcurrentlyWithNoDependency(playlist, context);
		}
	}
	else
	{
		context->actionCounter = -1;
		context->orderedOutput = false;
		DispatchTasksSerially(playlist, context);
	}

	context->outputSerializer->flush();
}


int main(int argc, const char * argv[])
{
	ReplayContext context;
	context.environment = env_map_from_environ();
	context.fileTreeRoot = NULL;
	context.outputSerializer = &OutputSerializer::shared();
	context.queue = nil;
	context.councurrencyLimit = 0; //unlimited
	context.actionCounter = -1;
	context.batchName = {};
	context.callbackPort = NULL;
	context.concurrent = true;
	context.analyzeDependencies = true;
	context.verbose = false;
	context.dryRun = false;
	context.stopOnError = false;
	context.force = false;
	context.orderedOutput = false;
	context.mcpServer = false;

	std::vector<std::string> playlistKeys;

	bool sandboxRequested = false;
	std::string sandboxProfilePath;
	std::vector<std::string> sandboxAllowRead;
	std::vector<std::string> sandboxAllowWrite;
	bool sandboxDenyNetwork = false;
	bool mcpServerMode = false;

	while(true)
	{
		int index = 0;
		int oneOption = getopt_long (argc, (char * const *)argv, "Vnst:pk:efor:l:m:vh", sLongOptions, &index);
		if (oneOption == -1) // end of options is signalled by -1
			break;

		switch(oneOption)
		{
			case 'v':
				context.verbose = true;
			break;
			
			case 'n':
				context.dryRun = true;
			break;

			case 's':
				context.concurrent = false;
			break;

			case 't':
			{
				 context.councurrencyLimit = strtol(optarg, (char **)NULL, 10);
				 if(context.councurrencyLimit < 0)
				 	context.councurrencyLimit = 0;
			}
			break;

			case 'p':
				context.analyzeDependencies = false;
			break;

			case 'k':
				// multiple playlists are allowed and stored to dispatch one after another
				playlistKeys.emplace_back(optarg);
			break;

			case 'e':
				context.stopOnError = true;
			break;
			
			case 'f':
				context.force = true;
			break;
			
			case 'o':
				context.orderedOutput = true;
			break;

			case 'r':
				// start server
				context.batchName = optarg;
			break;
			
			case 'l':
			{
				// log output to file
				int status = open_stdout_stream(optarg);
				if(status != EXIT_SUCCESS)
					return status;
			}
			break;
			
			case 'm':
			{
				// log errors/mistakes to file
				int status = open_stderr_stream(optarg);
				if(status != EXIT_SUCCESS)
					return status;
			}
			break;
			
			case kOptSandbox:
				sandboxRequested = true;
			break;

			case kOptAllowRead:
				sandboxRequested = true;
				sandboxAllowRead.emplace_back(optarg);
			break;

			case kOptAllowWrite:
				sandboxRequested = true;
				sandboxAllowWrite.emplace_back(optarg);
			break;

			case kOptSandboxProfile:
				sandboxRequested = true;
				sandboxProfilePath = optarg;
			break;

			case kOptDenyNetwork:
				sandboxRequested = true;
				sandboxDenyNetwork = true;
			break;

			case kOptMCPServer:
				mcpServerMode = true;
			break;

			case 'V':
				printf( "replay %s\n", STRINGIFY_VALUE(REPLAY_VERSION) );
				return EXIT_SUCCESS;
			break;

			case 'h':
			{
				DisplayHelp();
				return EXIT_SUCCESS;
			}
			break;
		}
	}

	// Determine playlist path (needed for both pre-sandbox extraction and execution).
	const char* playlistPath = (optind < argc) ? argv[optind] : nullptr;

	// Load the playlist once before the sandbox is applied so we can read the file freely.
	// The same in-memory document is reused for sandbox extraction and for execution.
	PlaylistDoc playlistDoc;
	if (playlistPath != nullptr)
	{
		std::string absPath = EnsureAbsolutePath(playlistPath);

		// Sandbox: allow reads from the playlist's own directory.
		if (sandboxRequested && !absPath.empty())
		{
			auto slash = absPath.rfind('/');
			if (slash != std::string::npos && slash > 0)
				sandboxAllowRead.emplace_back(absPath.substr(0, slash));
		}

		playlistDoc = LoadPlaylist(playlistPath, &context);

		// Extract sandbox paths from the already-loaded document — no second file read.
		if (sandboxRequested && playlistDoc.valid())
		{
			if (!playlistKeys.empty())
			{
				for (const auto& key : playlistKeys)
				{
					auto steps = playlistDoc.steps_for_key(key);
					ExtractPlaylistSandboxPaths(steps, context.environment,
					                             sandboxAllowRead, sandboxAllowWrite);
				}
			}
			else
			{
				auto steps = playlistDoc.root_steps();
				ExtractPlaylistSandboxPaths(steps, context.environment,
				                             sandboxAllowRead, sandboxAllowWrite);
			}
		}
	}

	// Apply sandbox before any real work. Once applied, the policy is
	// kernel-enforced on this process and every child it spawns.
	if(sandboxRequested)
	{
		if(!sandbox::InitializeSandbox(sandboxProfilePath, sandboxAllowRead, sandboxAllowWrite, !sandboxDenyNetwork, context.verbose))
			safe_exit(EXIT_FAILURE);
	}

	// --mcp-server: start MCP stdio server.
	// Allowed dirs come exclusively from --allow-read / --allow-write (both imply --sandbox).
	if(mcpServerMode)
	{
		MCPServerOptions mcpOpts;

		for (const auto &p : sandboxAllowRead)
        {
            std::string resolved_path = file_helpers::resolve_literal_path(p);
			mcpOpts.allowedDirs.push_back({resolved_path, false});
        }
        
        for (const auto &p : sandboxAllowWrite)
        {
            std::string resolved_path = file_helpers::resolve_literal_path(p);
			mcpOpts.allowedDirs.push_back({resolved_path, true});
        }
        
		context.mcpServer = true;
		int ret = RunMCPServer(&context, mcpOpts);
		safe_exit(ret);
	}

	// when executed with --start-server BATCH_NAME option start server and wait for messages in runloop
	if(!context.batchName.empty())
	{
		StartServerAndRunLoop(&context);
		safe_exit(context.lastError.hasError() ? EXIT_FAILURE : EXIT_SUCCESS);
	}

	if (playlistPath == nullptr)
	{
		StreamActionsFromStdIn(&context);
	}
	else if (!playlistKeys.empty())
	{
		if (!playlistDoc.valid())
		{
			LogError("Invalid or empty playlist \"%s\". No steps to replay\n", playlistPath);
			safe_exit(EXIT_SUCCESS);
		}

		for (const auto& key : playlistKeys)
		{
			auto steps = playlistDoc.steps_for_key(key);
			if (steps.empty())
			{
				LogError("Invalid or empty playlist for key \"%s\". No steps to replay\n", key.c_str());
				if (context.stopOnError)
					break;
				continue;
			}
			ProcessPlaylist(steps, &context);
		}
	}
	else
	{
		if (!playlistDoc.valid())
		{
			LogError("Invalid or empty playlist \"%s\". No steps to replay\n", playlistPath);
			safe_exit(EXIT_SUCCESS);
		}
		auto steps = playlistDoc.root_steps();
		if (steps.empty())
		{
			LogError("Invalid or empty playlist \"%s\". No steps to replay\n", playlistPath);
			safe_exit(EXIT_SUCCESS);
		}
		ProcessPlaylist(steps, &context);
	}

	// It looks like a lot of unnecessary Obj-C memory cleanup is happening at exit
	// and takes long time so skip it and just terminate the app now

	if(context.lastError.hasError())
		safe_exit(EXIT_FAILURE);

	safe_exit(EXIT_SUCCESS);

	return EXIT_SUCCESS; //unreachable
}
