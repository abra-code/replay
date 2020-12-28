#!/bin/sh

echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "  Stress-testing replay tool "
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


echo ""
echo "------------------------------"
echo ""
echo "Concurrent execution of many streamed [execute] actions"
echo ""

# My ~/Library contains about 1 million files
# 'find' takes about 2 min to list them:

echo "Find total number of files in \"$HOME/Library\" and assess how long it takes to list them with \"find\" tool"
echo "Start time:"
date
echo "time /usr/bin/find -s \"$HOME/Library\" | /usr/bin/wc -l"
time /usr/bin/find -s "$HOME/Library" | /usr/bin/wc -l

echo ""
echo "Stream as many actions to \"replay\" as many files found in \"$HOME/Library\""

# dry run execution of actions in my tests takes about 2 min as well
# this means that the execution of empty/printf tasks keeps up with the rate of input lines supply

echo ""
echo "Test 1: Dry run - actual actions are not executed but each task just prints out the status"
echo "Start time:"
date
echo "time /usr/bin/find -s \"$HOME/Library\" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | replay --dry-run | /usr/bin/wc -l"
time /usr/bin/find -s "$HOME/Library" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | "$REPLAY_TOOL" --dry-run | /usr/bin/wc -l

# ordering of output did not add any overhead in my tests
# this means the concurrent task execution still keeps up with the input supply

echo ""
echo "Test 2: Dry run - same as previous test but with ordering the output to assess the overhead"
echo "Start time:"
date
echo "time /usr/bin/find -s \"$HOME/Library\" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | replay --dry-run --ordered-output | /usr/bin/wc -l"
time /usr/bin/find -s "$HOME/Library" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | "$REPLAY_TOOL" --dry-run --ordered-output | /usr/bin/wc -l

echo ""
echo "Test 3: Print path with built-in echo per each file"
echo "Start time:"
date
echo "time /usr/bin/find -s \"$HOME/Library\" | /usr/bin/sed -E 's|(.+)|[echo]\t\1|' | replay --ordered-output | /usr/bin/wc -l"
time /usr/bin/find -s "$HOME/Library" | /usr/bin/sed -E 's|(.+)|[echo]\t\1|' | "$REPLAY_TOOL" --ordered-output | /usr/bin/wc -l


# This test takes long. My Macbook Pro 2016 4-core i7 takes 5-12 minutes for about 1 million files

echo ""
echo "Test 4: Execute child process with echo per each file"
echo "This test may take several min or longer per 1 million files!"
echo "Start time:"
date
echo "time /usr/bin/find -s \"$HOME/Library\" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | replay | /usr/bin/wc -l"
time /usr/bin/find -s "$HOME/Library" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | "$REPLAY_TOOL" | /usr/bin/wc -l


# Let's assess the overhead of scheduling slower tasks via "dispatch", which sends actions line by line to "replay"
# Running this experiment shows that for tasks which take any non-trivial amount of time the overhead disappears
# because the time to transfer the task from dispatch to replay is shorter than the execution time

# cannot re-pipe anything from replay server via dispatch so use stdout=false to avoid flooding the stdout

echo ""
echo "Test 5: \"dispatch\" overhead for child process echo per each file"
echo "This test may take long!"
echo "Start time:"
date

#echo "dispatch \"find-job\" start"
echo "time /usr/bin/find -s \"$HOME/Library\" | /usr/bin/sed -E 's|(.+)|[execute stdout=false]\t/bin/echo\t\1|' | dispatch \"find-job\""
echo "time dispatch \"find-job\" wait"

#"$DISPATCH" "find-job" start
time /usr/bin/find -s "$HOME/Library" | /usr/bin/sed -E 's|(.+)|[execute stdout=false]\t/bin/echo\t\1|' | "$DISPATCH" "find-job"
time "$DISPATCH" "find-job" wait

