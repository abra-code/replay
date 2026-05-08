#!/bin/sh

# Stress test for replay's concurrent dependency analysis.
# Each iteration runs several race-prone playlists and verifies that the
# scheduler correctly orders mutators against readers, producers, and other
# mutators. A wrong dependency graph would surface as flaky output here.
#
# Usage: test_replay_concurrency_stress.sh [path/to/replay] [repeat_count]
#
# Default repeat count is 60, which targets a total runtime under 10 seconds
# on a modern Mac. Pass a larger number to stress-test more aggressively.

success_counter=0
failure_counter=0

verify_eq()
{
	expected=$1
	actual=$2
	message=$3

	if [ "$expected" = "$actual" ]; then
		success_counter=$((success_counter+1))
	else
		failure_counter=$((failure_counter+1))
		echo ""
		echo "###########   ERROR   ##############"
		echo "$message"
		echo "  expected: $expected"
		echo "  actual:   $actual"
		echo "####################################"
		echo ""
	fi
}

verify_contains()
{
	haystack=$1
	needle=$2
	message=$3

	case "$haystack" in
		*"$needle"*)
			success_counter=$((success_counter+1))
			;;
		*)
			failure_counter=$((failure_counter+1))
			echo ""
			echo "###########   ERROR   ##############"
			echo "$message"
			echo "  needle: $needle"
			echo "  haystack: $haystack"
			echo "####################################"
			echo ""
			;;
	esac
}

count_occurrences()
{
	# count_occurrences "$haystack" "$needle"  →  number of occurrences (line-based grep -c is per-line, this is per-occurrence)
	printf '%s' "$1" | grep -o -F "$2" | wc -l | tr -d ' '
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
REPLAY_TOOL="${1:-$REPO_DIR/build/Release/replay}"
REPEAT_COUNT="${2:-60}"

if [ ! -x "$REPLAY_TOOL" ]; then
	echo "error: replay not found at $REPLAY_TOOL"
	echo "usage: $0 [path/to/replay] [repeat_count]"
	exit 1
fi

case "$REPEAT_COUNT" in
	''|*[!0-9]*)
		echo "error: repeat_count must be a positive integer (got: $REPEAT_COUNT)"
		echo "usage: $0 [path/to/replay] [repeat_count]"
		exit 1
		;;
esac

if [ "$REPEAT_COUNT" -lt 1 ]; then
	echo "error: repeat_count must be >= 1"
	exit 1
fi

WORK_DIR=$(/usr/bin/mktemp -d /tmp/replay_concurrency_stress.XXXXXX)
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "  Concurrent dependency-analysis stress test       "
echo "  Repeating each scenario $REPEAT_COUNT time(s)    "
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo ""
echo "Replay:  $REPLAY_TOOL"
echo "Workdir: $WORK_DIR"
echo ""

start_time=$(date +%s)

# ============================================================================
# Scenario 1: readers straddling a mutator
#   create foo (PRE)
#   read foo  (×3)            ← must observe PRE
#   edit foo PRE→POST
#   read foo  (×3)            ← must observe POST
# ============================================================================
scenario_straddle()
{
	iter=$1
	dir="$WORK_DIR/straddle_$iter"
	mkdir -p "$dir"
	file="$dir/f.txt"
	pl="$dir/pl.json"

	cat > "$pl" << EOF
[
  { "action": "create", "file": "$file", "content": "PRE" },
  { "action": "read", "items": ["$file"] },
  { "action": "read", "items": ["$file"] },
  { "action": "read", "items": ["$file"] },
  { "action": "edit", "items": ["$file"], "oldText": "PRE", "newText": "POST" },
  { "action": "read", "items": ["$file"] },
  { "action": "read", "items": ["$file"] },
  { "action": "read", "items": ["$file"] }
]
EOF
	out=$("$REPLAY_TOOL" "$pl" 2>&1)
	pre=$(count_occurrences "$out" "PRE")
	post=$(count_occurrences "$out" "POST")
	# Each pre-edit read prints a [text:...] header line and one "PRE" line.
	# Each post-edit read prints a [text:...] header line and one "POST" line.
	# The "POST" matches at substring level overlap with "PRE": "POST" doesn't
	# contain "PRE", so they're independent counts.
	verify_eq "3" "$pre" "straddle iter=$iter: 3 pre-edit readers must see PRE"
	verify_eq "3" "$post" "straddle iter=$iter: 3 post-edit readers must see POST"
	final=$(cat "$file")
	verify_eq "POST" "$final" "straddle iter=$iter: final content must be POST"
}

# ============================================================================
# Scenario 2: long in-place mutation chain on a single file
#   aaa → bbb → ccc → ddd → eee  via 4 sequential edits, then read
# ============================================================================
scenario_long_chain()
{
	iter=$1
	dir="$WORK_DIR/long_chain_$iter"
	mkdir -p "$dir"
	file="$dir/f.txt"
	pl="$dir/pl.json"

	cat > "$pl" << EOF
[
  { "action": "create", "file": "$file", "content": "aaa" },
  { "action": "edit", "items": ["$file"], "oldText": "aaa", "newText": "bbb" },
  { "action": "edit", "items": ["$file"], "oldText": "bbb", "newText": "ccc" },
  { "action": "edit", "items": ["$file"], "oldText": "ccc", "newText": "ddd" },
  { "action": "edit", "items": ["$file"], "oldText": "ddd", "newText": "eee" },
  { "action": "read", "items": ["$file"] }
]
EOF
	out=$("$REPLAY_TOOL" "$pl" 2>&1)
	verify_contains "$out" "eee" "long_chain iter=$iter: read must see final value"
	final=$(cat "$file")
	verify_eq "eee" "$final" "long_chain iter=$iter: file content"
}

# ============================================================================
# Scenario 3: glob-edit chain across many files
#   create dir/f1..f5 = "v1"
#   edit dir/*.txt v1→v2
#   edit dir/*.txt v2→v3
#   read each concretely — every file must end at v3
# ============================================================================
scenario_glob_chain()
{
	iter=$1
	dir="$WORK_DIR/glob_chain_$iter"
	mkdir -p "$dir/src"
	pl="$dir/pl.json"

	cat > "$pl" << EOF
[
  { "action": "create", "file": "$dir/src/f1.txt", "content": "v1" },
  { "action": "create", "file": "$dir/src/f2.txt", "content": "v1" },
  { "action": "create", "file": "$dir/src/f3.txt", "content": "v1" },
  { "action": "create", "file": "$dir/src/f4.txt", "content": "v1" },
  { "action": "create", "file": "$dir/src/f5.txt", "content": "v1" },
  { "action": "edit", "items": ["$dir/src/*.txt"], "oldText": "v1", "newText": "v2" },
  { "action": "edit", "items": ["$dir/src/*.txt"], "oldText": "v2", "newText": "v3" },
  { "action": "read", "items": ["$dir/src/f1.txt", "$dir/src/f2.txt", "$dir/src/f3.txt", "$dir/src/f4.txt", "$dir/src/f5.txt"] }
]
EOF
	out=$("$REPLAY_TOOL" "$pl" 2>&1)
	v3_count=$(count_occurrences "$out" "v3")
	verify_eq "5" "$v3_count" "glob_chain iter=$iter: 5 reads must observe v3"
	for n in 1 2 3 4 5; do
		final=$(cat "$dir/src/f$n.txt")
		verify_eq "v3" "$final" "glob_chain iter=$iter: f$n final content"
	done
}

# ============================================================================
# Scenario 4: cross-domain chain — glob → concrete → glob on overlapping path
#   create dir/{a,b}.cpp = "1"
#   edit dir/*.cpp 1→2          (glob mutator)
#   edit dir/a.cpp 2→A          (concrete; chains after glob due to overlap)
#   edit dir/*.cpp 2→3          (glob mutator; affects b.cpp only since a.cpp now "A")
#   Final: a.cpp=A, b.cpp=3
# ============================================================================
scenario_cross_domain()
{
	iter=$1
	dir="$WORK_DIR/cross_$iter"
	mkdir -p "$dir/src"
	pl="$dir/pl.json"

	cat > "$pl" << EOF
[
  { "action": "create", "file": "$dir/src/a.cpp", "content": "1" },
  { "action": "create", "file": "$dir/src/b.cpp", "content": "1" },
  { "action": "edit", "items": ["$dir/src/*.cpp"], "oldText": "1", "newText": "2" },
  { "action": "edit", "items": ["$dir/src/a.cpp"], "oldText": "2", "newText": "A" },
  { "action": "edit", "items": ["$dir/src/*.cpp"], "oldText": "2", "newText": "3" }
]
EOF
	"$REPLAY_TOOL" "$pl" >/dev/null 2>&1
	final_a=$(cat "$dir/src/a.cpp")
	final_b=$(cat "$dir/src/b.cpp")
	verify_eq "A" "$final_a" "cross_domain iter=$iter: a.cpp"
	verify_eq "3" "$final_b" "cross_domain iter=$iter: b.cpp"
}

# ============================================================================
# Scenario 5: wide fan-out — one producer, many independent consumers
#   create file
#   read file (×8 in playlist; scheduler may parallelize these)
# ============================================================================
scenario_fanout()
{
	iter=$1
	dir="$WORK_DIR/fanout_$iter"
	mkdir -p "$dir"
	file="$dir/f.txt"
	pl="$dir/pl.json"

	cat > "$pl" << EOF
[
  { "action": "create", "file": "$file", "content": "FANOUT" },
  { "action": "read", "items": ["$file"] },
  { "action": "read", "items": ["$file"] },
  { "action": "read", "items": ["$file"] },
  { "action": "read", "items": ["$file"] },
  { "action": "read", "items": ["$file"] },
  { "action": "read", "items": ["$file"] },
  { "action": "read", "items": ["$file"] },
  { "action": "read", "items": ["$file"] }
]
EOF
	out=$("$REPLAY_TOOL" "$pl" 2>&1)
	hits=$(count_occurrences "$out" "FANOUT")
	verify_eq "8" "$hits" "fanout iter=$iter: 8 readers must see content"
}

# ============================================================================
# Scenario 6: independent parallel mutators on disjoint files
#   create 4 files; each gets edited; each gets read.
#   Mutators are independent so the scheduler can run them in parallel.
# ============================================================================
scenario_parallel_independent()
{
	iter=$1
	dir="$WORK_DIR/par_$iter"
	mkdir -p "$dir"
	pl="$dir/pl.json"

	cat > "$pl" << EOF
[
  { "action": "create", "file": "$dir/p1.txt", "content": "x" },
  { "action": "create", "file": "$dir/p2.txt", "content": "x" },
  { "action": "create", "file": "$dir/p3.txt", "content": "x" },
  { "action": "create", "file": "$dir/p4.txt", "content": "x" },
  { "action": "edit", "items": ["$dir/p1.txt"], "oldText": "x", "newText": "ONE" },
  { "action": "edit", "items": ["$dir/p2.txt"], "oldText": "x", "newText": "TWO" },
  { "action": "edit", "items": ["$dir/p3.txt"], "oldText": "x", "newText": "THREE" },
  { "action": "edit", "items": ["$dir/p4.txt"], "oldText": "x", "newText": "FOUR" },
  { "action": "read", "items": ["$dir/p1.txt", "$dir/p2.txt", "$dir/p3.txt", "$dir/p4.txt"] }
]
EOF
	out=$("$REPLAY_TOOL" "$pl" 2>&1)
	verify_contains "$out" "ONE" "parallel_indep iter=$iter: read sees ONE"
	verify_contains "$out" "TWO" "parallel_indep iter=$iter: read sees TWO"
	verify_contains "$out" "THREE" "parallel_indep iter=$iter: read sees THREE"
	verify_contains "$out" "FOUR" "parallel_indep iter=$iter: read sees FOUR"
}

# ============================================================================
# Scenario 7: glob mutator with mixed pre/post readers on overlapping concrete paths
#   create dir/{a,b,c}.txt = "OLD"
#   read dir/a.txt          ← pre-mutation: must see OLD
#   read dir/b.txt          ← pre-mutation: must see OLD
#   edit dir/*.txt OLD→NEW  (glob mutator)
#   read dir/c.txt          ← post-mutation: must see NEW
#   read dir/a.txt          ← post-mutation: must see NEW
# ============================================================================
scenario_mixed_pre_post()
{
	iter=$1
	dir="$WORK_DIR/mix_$iter"
	mkdir -p "$dir/src"
	pl="$dir/pl.json"

	cat > "$pl" << EOF
[
  { "action": "create", "file": "$dir/src/a.txt", "content": "OLD" },
  { "action": "create", "file": "$dir/src/b.txt", "content": "OLD" },
  { "action": "create", "file": "$dir/src/c.txt", "content": "OLD" },
  { "action": "read", "items": ["$dir/src/a.txt"] },
  { "action": "read", "items": ["$dir/src/b.txt"] },
  { "action": "edit", "items": ["$dir/src/*.txt"], "oldText": "OLD", "newText": "NEW" },
  { "action": "read", "items": ["$dir/src/c.txt"] },
  { "action": "read", "items": ["$dir/src/a.txt"] }
]
EOF
	out=$("$REPLAY_TOOL" "$pl" 2>&1)
	old_count=$(count_occurrences "$out" "OLD")
	new_count=$(count_occurrences "$out" "NEW")
	verify_eq "2" "$old_count" "mixed_pp iter=$iter: 2 pre-mutation readers see OLD"
	verify_eq "2" "$new_count" "mixed_pp iter=$iter: 2 post-mutation readers see NEW"
}

# ============================================================================
# Scenario 8: parent-dir creator → edit child file (no per-file producer)
#   clone src/  →  cloned/
#   edit cloned/x.txt OLD→NEW
# The edit's path is created indirectly by the clone (clone declares only the
# top-level dir as an output). Without parent-walk linkage from the clone to
# the edit, edit may try to open cloned/x.txt before the clone finishes.
# ============================================================================
scenario_parent_then_edit()
{
	iter=$1
	dir="$WORK_DIR/parent_edit_$iter"
	mkdir -p "$dir/srcd"
	printf 'OLD' > "$dir/srcd/x.txt"
	printf 'OLD' > "$dir/srcd/y.txt"
	pl="$dir/pl.json"

	cat > "$pl" << EOF
[
  { "action": "clone", "from": "$dir/srcd", "to": "$dir/cloned" },
  { "action": "edit", "items": ["$dir/cloned/x.txt"], "oldText": "OLD", "newText": "NEW" },
  { "action": "edit", "items": ["$dir/cloned/y.txt"], "oldText": "OLD", "newText": "NEW" }
]
EOF
	"$REPLAY_TOOL" "$pl" >/dev/null 2>&1
	x=$(cat "$dir/cloned/x.txt" 2>/dev/null)
	y=$(cat "$dir/cloned/y.txt" 2>/dev/null)
	verify_eq "NEW" "$x" "parent_then_edit iter=$iter: x.txt edited after clone"
	verify_eq "NEW" "$y" "parent_then_edit iter=$iter: y.txt edited after clone"
}

# ============================================================================
# Run all scenarios REPEAT_COUNT times.
# Per-scenario per-iteration files live under WORK_DIR; the trap cleans up.
# ============================================================================

iter=1
while [ "$iter" -le "$REPEAT_COUNT" ]; do
	scenario_straddle "$iter"
	scenario_long_chain "$iter"
	scenario_glob_chain "$iter"
	scenario_cross_domain "$iter"
	scenario_fanout "$iter"
	scenario_parallel_independent "$iter"
	scenario_mixed_pre_post "$iter"
	scenario_parent_then_edit "$iter"
	iter=$((iter+1))
done

end_time=$(date +%s)
elapsed=$((end_time - start_time))

echo ""
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "  Finished concurrency stress tests                "
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo ""
echo "Iterations:                 $REPEAT_COUNT"
echo "Number of successful tests: $success_counter"
echo "Number of failed tests:     $failure_counter"
echo "Elapsed time:               ${elapsed}s"
echo ""

[ "$failure_counter" -eq 0 ]
