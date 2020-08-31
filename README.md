# replay
A macOS tool to execute a list of declared actions, primarily file operations like clone, move, create, delete

Key features:
- tiny binary
- concurrent file operations for fastest execution
- serial file operations supported if a sequence is required
- designed to replace custom shell scripts serially moving/copying files around
- self contained code - not calling external binaries to preform file operations
- supports cloning on APFS so duplicates don't take unnecessary space on disk

If it sounds a bit like an installer or package extractor it's becuase that's what it's designed to be used for.

Type `replay --help` in Terminal to learn more:
```
replay -- execute a declarative script of actions, aka a playlist

Usage: replay [options] <playlist_file.json|plist>

Options:

  -s, --serial       execute actions serially in the order specified in the playlist (slow)
                     default behavior is to execute actions concurrently with no order guarantee (fast)
  -k, --playlist-key KEY   declare a key in root dictionary of the playlist file for action steps array
                     if absent, the playlist file root container is assumed to be an array of action steps
                     the key may be specified multiple times to execute more than one playlist in the file
  -e, --stop-on-error   stop executing the remaining playlist actions on first error
  -f, --force        if the file operation fails, delete destination and try again
  -n, --dry-run      show a log of actions which would be performed without running them
  -v, --verbose      show a log of actions while they are executed
  -h, --help         display this help

Playlist format:

  Playlists can be composed in plist or JSON files
  In the usual form the root container of a plist or JSON file is a dictionary,
  where you can put one or more playlists with unique keys.
  A playlist is an array of action steps.
  Each step is a dictionary with action type and parameters. See below for actions and examples.
  If you don't specify the playlist key the root container is expected to be an array of action steps.
  More than one playlist may be present in a root dictionary. For example you may want preparation steps
  in one playlist to be executed by "replay" invocation with --serial option
  and have another concurrent playlist with the bulk of work executed by a second "replay" invocation

Environment variables expansion:

  Environment variables in form of ${VARIABLE} are expanded in all paths
  New file content may also contain environment variables in its body (with an option to turn off expansion)
  Missing environment variables or malformed text is considered an error and the action will not be executed
  It is easy to make a mistake and allowing evironment variables resolved to empty would result in invalid paths,
  potentially leading to destructive file operations

Actions and parameters:

  clone       Copy file(s) from one location to another. Cloning is supported on APFS volumes
              Source and destination for this action can be specified in 2 ways.
              One to one:
    from      source item path
    to        destination item path
              Or many items to destination directory:
    items     array of source item paths
    destination directory   path to output folder
  copy        Synonym for clone. Functionally identical.
  move        Move a file or directory
              Source and destination for this action can be specified the same way as for "clone"
  hardlink    Create a hardlink to source file
              Source and destination for this action can be specified the same way as for "clone"
  symlink     Create a symlink pointing to original file
              Source and destination for this action can be specified the same way as for "clone"
    validate   bool value to indicate whether to check for the existence of source file. Default is true
              it is usually a mistake if you try to create a symlink to nonexistent file
              that is why "validate" is true by default but it is possible to create a dangling symlink
              if you know what you are doing and really want that behavior, set "validate" to false
  create      Create a file or a directory
              you can create either a file with optional content or a directory but not both in one action step
    file      new file path (only for files)
    content   new file content string (only for files)
    raw content   bool value to indicate whether environment variables should be expanded or not
              default value is false, meaning that environment variables are expanded
              use true if you want to write a script with some ${VARIABLE} usage
    directory   new directory path. All directories leading to the deepest one are created if they don't exist
  delete      Delete a file or directory (with its content).
              CAUTION: There is no warning or user confirmation requested before deletion
    items     array of item paths to delete (files or directories with their content)
  execute     Run an executable as a child process
    tool      Full path to a tool to start
    arguments   array of arguments to pass to the tool (optional)

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
```
