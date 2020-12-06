# replay
A macOS tool to execute a list of declared actions, primarily file operations like clone, move, create, delete

Key features:
- concurrent file operations for fastest execution with automatic dependency resolution
- serial file operations supported if a sequence is required
- designed to replace custom shell scripts serially moving/copying files around
- self contained code - not calling external binaries to perform file operations
- supports cloning on APFS so duplicates don't take unnecessary space on disk
- small binary


Type `replay --help` in Terminal to read the following:

```

replay -- execute a declarative script of actions, aka a playlist

Usage: replay [options] [playlist_file.json|plist]

Options:

  -s, --serial       Execute actions serially in the order specified in the playlist (slow).
                     Default behavior is to execute actions concurrently, if possible, after dependency analysis (fast).
  -p, --no-dependency   An option for concurrent execution to skip dependency analysis. Actions must be independent.
  -k, --playlist-key KEY   Use a key in root dictionary of the playlist file for action steps array.
                     If absent, the playlist file root container is assumed to be an array of action steps.
                     The key may be specified multiple times to execute more than one playlist in the file.
  -e, --stop-on-error   Stop executing the remaining playlist actions on first error.
  -f, --force        If the file operation fails, delete destination and try again.
  -o, --ordered-output  In simple concurrent execution mode preserve the order of printed task outputs as specified
                     in the playlist. The tasks are still executed concurrently without order guarantee
                     but printing is ordered. Ignored in serial execution and concurrent execution with dependencies.
  -n, --dry-run      Show a log of actions which would be performed without running them.
  -v, --verbose      Show a log of actions while they are executed.
  -h, --help         Display this help

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
  2. Deletion and creation of the same file or directory in one playlist will result in creation first and
     deletion second because the deletion consumes the output of creation. If deletion is a required preparation step
     it should be executed in a separate playlist before the main tasks are scheduled. You may pass --playlist-key
     multiple times as a parameter and the playlists will be executed one after another in the order specified.
  3. Moving or deleting an item makes it unusable for other actions at the original path. Such actions are exclusive
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

Streaming actions through stdin pipe:

"replay" allows sending a stream of actions via stdin when the playlist file is not specified.
Actions may be executed serially or concurrently but without dependency analysis.
Dependency analysis requires a complete set of actions to create a graph, while streaming
starts execution immediately as the action requests arrive.
Concurrent execution is default, which does not guarantee the order of actions but a new option:
--ordered-output has been added to ensure the output order is the same as action scheduling order.
For example, while streaming actions A, B, C in that order, the execution may happen like this: A, C, B
but the printed output will still be preserved as A, B, C. This implies that that output of C
will be delayed if B is taking long to finish.

The format of streamed/piped actions is one action per line (not plist of json!), as follows:
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
In the following example uses a different separator: "+" to explicitly show delimited parameters:
[execute]+/bin/sh+-c+/bin/ls ${HOME} | /usr/bin/grep ".txt"

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
./replay --dry-run --playlist-key "Shepherd Playlist" shepherd.plist

In the above example playlist some output files are inputs to later actions.
The dependency analysis will create an execution graph to run dependent actions after the required outputs are produced.


```
