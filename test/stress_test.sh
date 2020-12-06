#! /bin/sh

echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "  Stress-resting replay tool "
echo "  These tests may take long! "
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo ""

REPLAY_TOOL=$1
echo "REPLAY_TOOL = $REPLAY_TOOL"

if test -z "$REPLAY_TOOL"; then
	echo "Usage: ./stress_test.sh /path/to/built/replay"
	exit 1
fi


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

# This test takes long. My Macbook Pro 2016 4-core i7 took 12 minutes for about 1 million files
# Subtracting the baseline 2 min for 'find', it means about 1 million child process executions in 10 minutes
# at the rate of about 1700 simple child processes (echo) per second

echo ""
echo "Test 3: Execute child process with echo per each file"
echo "This test may take 12 min or longer per 1 million files!"
echo "Start time:"
date
echo "time /usr/bin/find -s \"$HOME/Library\" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | replay | /usr/bin/wc -l"
time /usr/bin/find -s "$HOME/Library" | /usr/bin/sed -E 's|(.+)|[execute]\t/bin/echo\t\1|' | "$REPLAY_TOOL" | /usr/bin/wc -l
