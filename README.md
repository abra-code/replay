# replay
A macOS tool to execute a list of declared actions. Currently supported actions are:
- file operations like clone, move, create, delete,
- execution of a child tool,
- text operations like echo

Key features:
- concurrent operations for fastest execution with optional automatic dependency resolution
- serial operations supported if a sequence is required
- designed to improve performance of shell scripts running a series of slow tasks, which
  underutilize the CPU, storage or network resources
- self contained code - not calling external tools to perform file operations
- supports cloning on APFS so duplicates don't take unnecessary space on disk
- companion "dispatch" tool helps with ad hoc task distribution without the need to create a playlist

The documentation is in both tools' help as below. Example usage in test scripts accompanying this code.
\
Example application can be found in Delta.app, where it is combined with find tool and delivers about 5-fold speed increase:
\
https://github.com/abra-code/DeltaApp
\
\
The content of `replay --help`:

```

replay -- execute a declarative script of actions, aka a playlist

Usage:

  replay [options] [playlist_file.json|plist]

Options:

  -k, --playlist-key KEY   Use a key in root dictionary of the playlist file for action steps array.
                     If absent, the playlist file root container is assumed to be an array of action steps.
                     The key may be specified multiple times to execute more than one playlist in the file.
  -s, --serial       Execute actions serially in the order specified in the playlist (slow).
                     Default behavior is to execute actions concurrently, if possible, after dependency analysis (fast).
  -p, --no-dependency   An option for concurrent execution to skip dependency analysis. Actions must be independent.
  -o, --ordered-output   In simple concurrent execution mode preserve the order of printed task outputs as specified
                     in the playlist. The tasks are still executed concurrently without order guarantee
                     but printing is ordered. Ignored in serial execution and concurrent execution with dependencies.
  -t, --max-tasks NUMBER   Maximum number of concurrently executed actions. Default is 0, which is treated as unbound.
                     Limiting the number of concurrent operations may sometimes result in faster execution.
                     With intensive file I/O tasks a low number like 4 may yield the best performance.
                     For CPU intensive tasks you may use logical CPU core count (or a multiplier) as obtained by:
                     sysctl -n hw.ncpu
  -e, --stop-on-error   Stop executing the remaining playlist actions on first error.
  -f, --force        If the file operation fails, delete destination and try again.
  -n, --dry-run      Show a log of actions which would be performed without running them.
  -v, --verbose      Show a log of actions while they are executed.
  -r, --start-server BATCH_NAME   Start server and listen for dispatch requests. "BATCH_NAME" must be a unique name
                     identifying a group of actions to be executed concurrently. Subsequent requests to add actions
                     with "dispatch" tool must refer to the same name. "replay" server listens to request messages
                     sent by "dispatch". If the server is not running for given batch name, the first request to add
                     an action starts "replay" in server mode. Therefore starting the server manually is not required
                     but it is possible if needed.
  -l, --stdout PATH  log standard output to provided file path.
  -m, --stderr PATH  log standard error to provided file path.
  -i, --version      Display version.
  -h, --help         Display this help.

Playlist format:

  Playlists can be composed in plist or JSON files.
  In the usual form the root container of a plist or JSON file is a dictionary,
  where you can put one or more playlists with unique keys.
  A playlist is an array of action steps.
  Each step is a dictionary with action type and parameters. See below for actions and examples.
  If you don't specify the playlist key, the root container is expected to be an array of action steps.
  More than one playlist may be present in a root dictionary. For example, you may want preparation steps
  in one playlist to be executed by "replay" invocation with --serial option
  and have another concurrent playlist with the bulk of work executed by a second "replay" invocation

Environment variables expansion:

  Environment variables in form of ${VARIABLE} are expanded in all paths.
  New file content may also contain environment variables in its body (with an option to turn off expansion).
  Missing environment variables or malformed text is considered an error and the action will not be executed.
  It is easy to make a mistake and allowing evironment variables resolved to empty would result in invalid paths,
  potentially leading to destructive file operations.

Dependency analysis:

  In default execution mode (without --serial or --no-dependency option) "replay" performs dependency analysis
  and constructs an execution graph based on files consumed and produced by actions.
  If a file produced by action A is needed by action B, action B will not be executed until action A is finished.
  For example: if your playlist contains an action to create a directory and other actions write files
  into this directory, all these file actions will wait for directory creation to be finished and then they will
  be executed concurrently if otherwise independent from each other.
  Concurrent execution imposes a couple of rules on actions:
  1. No two actions may produce the same output. With concurrent execution this would produce undeterministic results
     depending on which action happened to run first or fail if they accessed the same file for writing concurrently.
     "replay" will not run any actions when this condition is detected during dependency analysis.
  2. Action dependencies must not create a cycle. In other words the dependency graph must be a proper DAG.
     An example cycle is one action copying file A to B and another action copying file B to A.
     Replay algorithm tracks the number of unsatisifed dependencies for each action. When the number drops to zero,
     the action is dispatched for execution. For actions in a cycle that number never drops to zero and they can
     never be dispatched. After all dispatched tasks are done "replay" verifies all actions in the playlist
     were executed and reports a failure if they were not, listing the ones which were skipped.
  3. Deletion and creation of the same file or directory in one playlist will result in creation first and
     deletion second because the deletion consumes the output of creation. If deletion is a required preparation step
     it should be executed in a separate playlist before the main tasks are scheduled. You may pass --playlist-key
     multiple times as a parameter and the playlists will be executed one after another in the order specified.
  4. Moving or deleting an item makes it unusable for other actions at the original path. Such actions are exclusive
     consumers of given input paths and cannot share their inputs with other actions. Producing additional items under
     such exclusive input paths is also not allowed. "replay" will report an error during dependency analysis
     and will not execute an action graph with exclusive input violations.

Actions and parameters:

  clone       Copy file(s) from one location to another. Cloning is supported on APFS volumes.
              Source and destination for this action can be specified in 2 ways.
              One to one:
    from      Source item path.
    to        Destination item path.
              Or many items to destination directory:
    items     Array of source item paths.
    destination directory   Path to output folder.
  copy        Synonym for clone. Functionally identical.
  move        Move a file or directory.
              Source and destination for this action can be specified the same way as for "clone".
              Source path(s) are invalidated by "move" so they are marked as exclusive in concurrent execution.
  hardlink    Create a hardlink to source file.
              Source and destination for this action can be specified the same way as for "clone".
  symlink     Create a symlink pointing to original file.
              Source and destination for this action can be specified the same way as for "clone".
    validate   Bool value to indicate whether to check for the existence of source file. Default is true.
              It is usually a mistake if you try to create a symlink to nonexistent file,
              that is why "validate" is true by default but it is possible to create a dangling symlink.
              If you know what you are doing and really want that behavior, set "validate" to false.
  create      Create a file or a directory.
              You can create either a file with optional content or a directory but not both in one action step.
    file      New file path (only for files).
    content   New file content string (only for files).
    raw       Bool value to indicate whether environment variables should be expanded or not in content text.
              Default value is "false", meaning that environment variables are expanded.
              Pass "true" if you want to write a script with some ${VARIABLE} usage
    directory   New directory path. All directories leading to the deepest one are created if they don't exist.
  delete      Delete a file or directory (with its content).
              CAUTION: There is no warning or user confirmation requested before deletion.
    items     Array of item paths to delete (files or directories with their content).
              Item path(s) are invalidated by "delete" so they are marked as exclusive in concurrent execution.
  execute     Run an executable as a child process.
    tool      Full path to a tool to execute.
    arguments   Array of arguments to pass to the tool (optional).
    inputs    Array of file paths read by the tool during execution (optional).
    exclusive inputs    Array of file paths invalidated (items deleted or moved) by the tool (rare, optional).
    outputs   Array of file paths writen by the tool during execution (optional).
    stdout    Bool value to indicate whether the output of the tool should be printed to stdout (optional).
              Default value is "true", indicating the output from child process is printed to stdout.
  echo        Print a string to stdout.
    text      The text to print.
    raw       Bool value to indicate whether environment variable expansion should be suppressed. Default is "false".
    newline   Bool value to indicate whether the output string should be followed by newline. Default is "true".

Streaming actions through stdin pipe:

"replay" allows sending a stream of actions via stdin when the playlist file is not specified.
Actions may be executed serially or concurrently but without dependency analysis.
Dependency analysis requires a complete set of actions to create a graph, while streaming
starts execution immediately as the action requests arrive.
Concurrent execution is default, which does not guarantee the order of actions but an option:
--ordered-output has been added to ensure the output order is the same as action scheduling order.
For example, while streaming actions A, B, C in that order, the execution may happen like this: A, C, B
but the printed output will still be preserved as A, B, C. This implies that that output of C
will be delayed if B is taking long to finish.

The format of streamed/piped actions is one action per line (not plist or json!), as follows:
- ignore whitespace characters at the beginning of the line, if any
- action and options come first in square brackets, e.g.: [clone], [move], [delete], [create file] [create directory]
  some options can be added as key=value as described in "Actions and parmeters" section above with examples below
- the first character following the closing square bracket ']' is used as a field delimiter for the parameters to the action
- variable length parameters are following, separated by the same field separator, specific to given action
Param interpretation per action
(examples use "tab" as a separator)
1. [clone], [move], [hardlink], [symlink] allows only simple from-to specification,
with first param interpretted as "from" and second as "to" e.g.:
[clone]	/path/to/src/file.txt	/path/to/dest/file.txt
[symlink validate=false]	/path/to/src/file.txt	/path/to/symlink/file.txt
2. [delete] is followed by one or many paths to items, e.g.:
[delete]	/path/to/delete/file1.txt	/path/to/delete/file2.txt
3. [create] has 2 variants: [create file] and [create directory].
If "file" or "directory" option is not specified, it falls back to "file"
A. [create file] requires path followed by optional content, e.g.:
[create file]	/path/to/create/file.txt	Created by replay!
[create file raw=true]	/path/to/file.txt	Do not expand environment variables like ${HOME}
B. [create directory] requires just a single path, e.g.:
[create directory]	/path/to/create/directory
4. [execute] requires tool path and may have optional parameters separated with the same delimiter (not space delimited!), e.g.:
[execute]	/bin/echo	Hello from replay!
[execute stdout=false]	/bin/echo	This will not be printed
The following example uses a different separator: "+" to explicitly show delimited parameters:
[execute]+/bin/sh+-c+/bin/ls ${HOME} | /usr/bin/grep ".txt"
5. [echo] requires one string after separator. Supported modifiers are raw=true and newline=false

Example JSON playlist:

{
  "Shepherd Playlist": [
    {
      "action": "create",
      "directory": "${HOME}/Pen",
    },
    {
      "action": "clone",
      "from": "${HOME}/sheep.txt",
      "to": "${HOME}/Pen/clone.txt",
    },
    {
      "action": "move",
      "items": [
          "${HOME}/sheep1.txt",
          "${HOME}/sheep2.txt",
          "${HOME}/sheep3.txt",
          ],
      "destination directory": "${HOME}/Pen",
    },
    {
      "action": "delete",
      "items": [
          "${HOME}/Pen/clone.txt",
          ],
    },
  ],
}

Example plist playlist:

<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Shepherd Playlist</key>
    <array>
        <dict>
            <key>action</key>
            <string>create</string>
            <key>directory</key>
            <string>${HOME}/Pen</string>
        </dict>
        <dict>
            <key>action</key>
            <string>clone</string>
            <key>from</key>
            <string>${HOME}/sheep.txt</string>
            <key>to</key>
            <string>${HOME}/Pen/clone.txt</string>
        </dict>
        <dict>
            <key>action</key>
            <string>move</string>
            <key>items</key>
            <array>
                <string>${HOME}/sheep1.txt</string>
                <string>${HOME}/sheep2.txt</string>
                <string>${HOME}/sheep3.txt</string>
            </array>
            <key>destination directory</key>
            <string>${HOME}/Pen</string>
        </dict>
        <dict>
            <key>action</key>
            <string>delete</string>
            <key>items</key>
            <array>
                <string>${HOME}/Pen/clone.txt</string>
            </array>
        </dict>
    </array>
</dict>
</plist>

Example execution:

  replay --dry-run --playlist-key "Shepherd Playlist" shepherd.plist

In the above example playlist some output files are inputs to later actions.
The dependency analysis will create an execution graph to run dependent actions after the required outputs are produced.

See also:

  dispatch --help

```

#  
The content of  `dispatch --help`:
 
```

dispatch -- companion tool for "replay" to simplify adding tasks for concurrent execution

Usage:

  dispatch batch-name [action-name] [action params]

Description:

  "dispatch" starts "replay" in server mode as a background process and sends tasks to it.
Batch name is a required user-provided parameter to all invocations identifying a task batch.
A batch can be understood as a single job with mutiple tasks. Each instance of "replay"
running in a server mode is associated with one uniqueley named batch/job.
"dispatch" is just a client-facing helper tool to send tasks to "replay" server.
It is intended for ad hoc execution of unstructured tasks when the rate of scheduling tasks
is higher than their execution time and they can be run concurrently.
Invoking "dispatch batch-name wait" at the end allows the client script to wait for all
scheduled tasks to finish.
A typical sequence of calls could be demonstrated by the following example:

   dispatch example-batch echo "Starting the batch job"
   dispatch example-batch create file ${HOME}/she-sells.txt 'she sells'
   dispatch example-batch execute /bin/sh -c "/bin/echo 'sea shells' > ${HOME}/shells.txt"
   dispatch example-batch execute /bin/sleep 10
   dispatch example-batch wait

The first invocation of "dispatch" for unique batch name starts a new instance of "replay"
server with default parameters. If you wish to control "replay" behavior you can start it
explicitly with "start" action and provide parameters to forward to "replay", for example:

   dispatch example-batch start --verbose --ordered-output --stop-on-error

Subsequent use of "start" action for the same batch name will not restart the server
but a warning will be printed about already running server instance.

Supported actions are the same as "replay" actions plus a couple of special control words:

   start [replay options]
   clone /from/item/path /to/item/path
   copy /from/item/path /to/item/path
   move /from/item/path /to/item/path
   hardlink /from/item/path /to/item/path
   symlink /from/item/path /to/item/path
   create file /path/to/new/file "New File Content"
   create directory /path/to/new/dir
   delete /path/to/item1 /path/to/item2 /path/to/itemN
   execute /path/to/tool param1 param2 paramN
   echo "String to print"
   wait

If invoked without any action name, "dispatch" opens a standard input for streaming actions
in the same format as accepted by "replay" tool, for example:

   echo "[echo]|Streaming actions" | dispatch stream-job
   echo "[execute]|/bin/ls|-la" | dispatch stream-job
   dispatch stream-job wait

With a couple of notes:
 - you cannot pass "start" and "wait" options that way - these are instructions for
   "dispatch" tool, not real actions to forward to "replay".
 - each line is sent to "replay" server separately so it is not as performant as streaming
   actions directly to "replay" in regular, non-server mode.
 - "replay" stdout cannot be piped when executed this way but "replay" can be started
   with --stdout /path/to/log.out and --stderr /path/to/log.err options keep the logs.
 - a reminder that streaming actions as text requires parameters to be separated by some
   non-interfering field separator (vertical bar in the above example).


Options:

  -i, --version      Display version.
  -h, --help         Display this help

See also:

  replay --help

```

#  
The content of  `fingerprint --help`:
 
```

Usage: fingerprint [-g, --glob=PATTERN]... [OPTIONS]... [PATH]...
Calculate a combined hash, aka fingerprint, of all files in specified path(s) matching the GLOB pattern(s)
OPTIONS:
  -g, --glob=PATTERN  Glob patterns (repeatable, unexpanded) to match files under directories
  -H, --hash=ALGO     File content hash algorithm: crc32c (default) or blake3
  -F, --fingerprint-mode=MODE  Options to include paths in final fingerprint:
        default  : only file content hashes (rename-insensitive) - default if not specified
        absolute : include full absolute paths (detects moves/renames)
        relative : use relative paths when under searched dirs (recommended)
  -X, --xattr=MODE    Control extended attribute (xattr) hash caching:
        on      : use cache if valid, update if changed - default
        off     : disable xattr caching
        refresh : force recompute and update xattrs
        clear   : disable caching and delete existing xattrs
  -I, --inputs=FILE   Read input paths from FILE (one path per line, repeatable)
                      Supports Xcode .xcfilelist with ${VAR}/$(VAR) and plain lists.
  -l, --list          List matched files with their hashes
  -h, --help          Print this help message
  -v, --verbose       Print all status information

PATH arguments (positional) can be:
  - Directories for recursive traversal
  - Individual files to fingerprint directly
  - Symlinks (entire symlink chains are followed and fingerprinted)
  - Non-existent paths (treated as files with sentinel hash value)

Paths can be absolute or relative. Relative paths are resolved against the current directory.
Glob patterns apply only to files discovered during directory traversal, not to directly specified files.
When no glob pattern is specified, all files under provided directories are fingerprinted.

With --xattr=ON the tool caches computed file hashes and saves FileInfo in "public.fingerprint.crc32c"
or "public.fingerprint.blake3" xattr for files, depending on hash choice and then reads it back on next
fingerprinting if file inode, size and modification dates are unchanged.
FileInfo is a 32 byte structure:
	"inode" : 8 bytes,
	"size" : 8 bytes,
	"mtime_ns" : 8 bytes,
	{ crc32c : 4 bytes, reserved: 4 bytes } or blake3 : 8 bytes
xattr caching option significantly speeds up subsequent fingerprinting after initial hash calculation.
Turning it off makes the tool always perform file hashing, which might be justified in a zero trust
hostile environment at the file I/O and CPU expense. In a trusted or non-critical environment without malicious suspects,
the combination of lightweight crc32c and xattr caching provides excellent performance and very low chances of collisions.

```

