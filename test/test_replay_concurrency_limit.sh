#!/bin/sh

echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "  Concurrency limit tests    "
echo "  These tests may take long! "
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo ""

REPLAY_TOOL=$1
echo "REPLAY_TOOL = $REPLAY_TOOL"

if test -z "$REPLAY_TOOL"; then
	echo "Usage: ./stress_test.sh /path/to/built/replay"
	exit 1
fi

REPLAY_PARENT_DIR=$(dirname "$REPLAY_TOOL")

DISPATCH="$REPLAY_PARENT_DIR/dispatch"
if test ! -f "$DISPATCH"; then
	echo "Error: \"dispatch\" tool is expected to be in the same directory as \"dispatch\""
	exit 1
fi

echo "DISPATCH = $DISPATCH"

logical_core_count=$(/usr/sbin/sysctl -n hw.ncpu)

echo ""
echo "Test 1: Print path with echo per each file - unlimited"
echo "Start time:"
date
echo "time /usr/bin/find -s \"$HOME/Library/Application Support\" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | replay | /usr/bin/wc -l"
time /usr/bin/find -s "$HOME/Library/Application Support" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | "$REPLAY_TOOL" | /usr/bin/wc -l

echo ""
echo "Test 1.1: Print path with echo per each file with concurrency - limit to logical number of cores"
echo "Logical core count = $logical_core_count"
echo "Start time:"
date
echo "time /usr/bin/find -s \"$HOME/Library/Application Support\" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | replay --max-tasks $logical_core_count | /usr/bin/wc -l"
time /usr/bin/find -s "$HOME/Library/Application Support" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | "$REPLAY_TOOL" --max-tasks $logical_core_count  | /usr/bin/wc -l

echo ""
echo "Test 1.2: Print path with echo per each file with concurrency - limit 32"
echo "Start time:"
date
echo "time /usr/bin/find -s \"$HOME/Library/Application Support\" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | replay --max-tasks 32 | /usr/bin/wc -l"
time /usr/bin/find -s "$HOME/Library/Application Support" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | "$REPLAY_TOOL" --max-tasks 32  | /usr/bin/wc -l

echo ""
echo "Test 1.3: Print path with echo per each file with concurrency - limit 16"
echo "Start time:"
date
echo "time /usr/bin/find -s \"$HOME/Library/Application Support\" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | replay --max-tasks 16 | /usr/bin/wc -l"
time /usr/bin/find -s "$HOME/Library/Application Support" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | "$REPLAY_TOOL" --max-tasks 16  | /usr/bin/wc -l

echo ""
echo "Test 1.4: Print path with echo per each file with concurrency - limit 8"
echo "Start time:"
date
echo "time /usr/bin/find -s \"$HOME/Library/Application Support\" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | replay --max-tasks 8 | /usr/bin/wc -l"
time /usr/bin/find -s "$HOME/Library/Application Support" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | "$REPLAY_TOOL" --max-tasks 8  | /usr/bin/wc -l

echo ""
echo "Test 1.5: Print path with echo per each file with concurrency - limit 4"
echo "Start time:"
date
echo "time /usr/bin/find -s \"$HOME/Library/Application Support\" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | replay --max-tasks 4 | /usr/bin/wc -l"
time /usr/bin/find -s "$HOME/Library/Application Support" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | "$REPLAY_TOOL" --max-tasks 4  | /usr/bin/wc -l

echo ""
echo "Test 1.6: Print path with echo per each file with concurrency - limit 2"
echo "Start time:"
date
echo "time /usr/bin/find -s \"$HOME/Library/Application Support\" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | replay --max-tasks 2 | /usr/bin/wc -l"
time /usr/bin/find -s "$HOME/Library/Application Support" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | "$REPLAY_TOOL" --max-tasks 2  | /usr/bin/wc -l

echo ""
echo "-------------------------------------------------------------------------------"

echo ""
echo "Test 2: File I/O heavy: read executable files with /usr/bin/strings - unlimited"
echo "Start time:"
date
echo "time /usr/bin/find -s \"/Applications/Xcode.app/Contents/Developer/Platforms\" -type f -perm '+u=x,g=x,o=x' | /usr/bin/sed -E 's|(.+)|[execute stdout=false]\t/usr/bin/strings\t\1|' | replay"
time /usr/bin/find -s "/Applications/Xcode.app/Contents/Developer/Platforms" -type f -perm '+u=x,g=x,o=x' | /usr/bin/sed -E 's|(.+)|[execute stdout=false]\t/usr/bin/strings\t\1|' | "$REPLAY_TOOL"


echo ""
echo "Test 2.1: File I/O heavy: read executable files in Xcode.app with /usr/bin/strings - limit to logical number of cores"
echo "Logical core count = $logical_core_count"
echo "Start time:"
date
echo "time /usr/bin/find -s \"/Applications/Xcode.app/Contents/Developer/Platforms\" -type f -perm '+u=x,g=x,o=x' | /usr/bin/sed -E 's|(.+)|[execute stdout=false]\t/usr/bin/strings\t\1|' | replay --max-tasks $logical_core_count"
time /usr/bin/find -s "/Applications/Xcode.app/Contents/Developer/Platforms" -type f -perm '+u=x,g=x,o=x' | /usr/bin/sed -E 's|(.+)|[execute stdout=false]\t/usr/bin/strings\t\1|' | "$REPLAY_TOOL" --max-tasks $logical_core_count

echo ""
echo "Test 2.2: File I/O heavy: read executable files in Xcode.app with /usr/bin/strings - limit 16"
echo "Start time:"
date
echo "time /usr/bin/find -s \"/Applications/Xcode.app/Contents/Developer/Platforms\" -type f -perm '+u=x,g=x,o=x' | /usr/bin/sed -E 's|(.+)|[execute stdout=false]\t/usr/bin/strings\t\1|' | replay --max-tasks 16"
time /usr/bin/find -s "/Applications/Xcode.app/Contents/Developer/Platforms" -type f -perm '+u=x,g=x,o=x' | /usr/bin/sed -E 's|(.+)|[execute stdout=false]\t/usr/bin/strings\t\1|' | "$REPLAY_TOOL" --max-tasks 16

echo ""
echo "Test 2.3: File I/O heavy: read executable files in Xcode.app with /usr/bin/strings - limit 8"
echo "Start time:"
date
echo "time /usr/bin/find -s \"/Applications/Xcode.app/Contents/Developer/Platforms\" -type f -perm '+u=x,g=x,o=x' | /usr/bin/sed -E 's|(.+)|[execute stdout=false]\t/usr/bin/strings\t\1|' | replay --max-tasks 8"
time /usr/bin/find -s "/Applications/Xcode.app/Contents/Developer/Platforms" -type f -perm '+u=x,g=x,o=x' | /usr/bin/sed -E 's|(.+)|[execute stdout=false]\t/usr/bin/strings\t\1|' | "$REPLAY_TOOL" --max-tasks 8

echo ""
echo "Test 2.4: File I/O heavy: read executable files in Xcode.app with /usr/bin/strings - limit 4"
echo "Start time:"
date
echo "time /usr/bin/find -s \"/Applications/Xcode.app/Contents/Developer/Platforms\" -type f -perm '+u=x,g=x,o=x' | /usr/bin/sed -E 's|(.+)|[execute stdout=false]\t/usr/bin/strings\t\1|' | replay --max-tasks 4"
time /usr/bin/find -s "/Applications/Xcode.app/Contents/Developer/Platforms" -type f -perm '+u=x,g=x,o=x' | /usr/bin/sed -E 's|(.+)|[execute stdout=false]\t/usr/bin/strings\t\1|' | "$REPLAY_TOOL" --max-tasks 4

echo ""
echo "Test 2.5: File I/O heavy: read executable files in Xcode.app with /usr/bin/strings - limit 2"
echo "Start time:"
date
echo "time /usr/bin/find -E \"/Applications/Xcode.app/Contents/Developer/Platforms\" -type f -perm '+u=x,g=x,o=x' | /usr/bin/sed -E 's|(.+)|[execute stdout=false]\t/usr/bin/strings\t\1|' | replay --max-tasks 2"
time /usr/bin/find -s "/Applications/Xcode.app/Contents/Developer/Platforms" -type f -perm '+u=x,g=x,o=x' | /usr/bin/sed -E 's|(.+)|[execute stdout=false]\t/usr/bin/strings\t\1|' | "$REPLAY_TOOL" --max-tasks 2

