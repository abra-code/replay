#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
TOOL="${1:-$REPO_DIR/build/Release/globoverlap}"
PASS=0
FAIL=0

if [ ! -x "$TOOL" ]; then
    echo "Building globoverlap..."
    /bin/mkdir -p "$REPO_DIR/build/Release"
    /usr/bin/clang++ -std=c++20 -O2 -I"$REPO_DIR/glob-overlap/include" -I"$REPO_DIR/glob-cpp/include" "$REPO_DIR/glob-overlap/globoverlap.cpp" -o "$TOOL"
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "Build failed"
        exit 2
    fi
fi

expect_overlap() {
    "$TOOL" "$1" "$2" > /dev/null 2>&1
    rc=$?
    if [ $rc -eq 0 ]; then
        ((PASS++))
    else
        ((FAIL++))
        echo "FAIL: expected overlap:    '$1'  vs  '$2'"
    fi
}

expect_no_overlap() {
    "$TOOL" "$1" "$2" > /dev/null 2>&1
    rc=$?
    if [ $rc -eq 1 ]; then
        ((PASS++))
    else
        ((FAIL++))
        echo "FAIL: expected no overlap: '$1'  vs  '$2'"
    fi
}

echo "=== Identical patterns ==="
expect_overlap "*.o" "*.o"
expect_overlap "build/**/*.o" "build/**/*.o"
expect_overlap "src/main.cpp" "src/main.cpp"

echo "=== Concrete vs concrete ==="
expect_no_overlap "src/main.cpp" "src/util.cpp"
expect_overlap "build/foo.o" "build/foo.o"

echo "=== Extension mismatch ==="
expect_no_overlap "build/**/*.o" "build/**/*.lib"
expect_no_overlap "*.cpp" "*.h"
expect_no_overlap "src/**/*.cpp" "src/**/*.h"

echo "=== Prefix divergence ==="
expect_no_overlap "src/**/*.o" "build/**/*.o"
expect_no_overlap "src/*.cpp" "build/*.cpp"
expect_no_overlap "aaa/*" "bbb/*"

echo "=== Overlapping with globstar ==="
expect_overlap "build/**/*.o" "build/foo/bar.o"
expect_overlap "build/**/*.o" "build/*.o"
expect_overlap "build/**/*.o" "build/sub/**/*.o"
expect_overlap "src/**/*.cpp" "src/**/test*.cpp"

echo "=== Star overlap ==="
expect_overlap "build/*.o" "build/foo.o"
expect_overlap "build/*.o" "build/f*.o"
expect_overlap "build/*" "build/foo.o"

echo "=== Star no overlap ==="
expect_no_overlap "build/*.o" "build/*.lib"
expect_no_overlap "build/foo.*" "build/bar.*"

echo "=== Depth mismatch (no globstar) ==="
expect_no_overlap "build/*.o" "build/sub/*.o"
expect_no_overlap "*.o" "build/*.o"

echo "=== Braces ==="
expect_overlap "build/*.{o,lib}" "build/*.o"
expect_overlap "build/*.{o,lib}" "build/*.lib"
expect_no_overlap "build/*.{o,lib}" "build/*.h"

echo "=== Sets ==="
expect_overlap "build/[abc].o" "build/a.o"
expect_no_overlap "build/[abc].o" "build/d.o"
expect_overlap "build/[a-z].o" "build/?.o"

echo "=== Question mark ==="
expect_overlap "build/?.o" "build/a.o"
expect_overlap "build/??.o" "build/ab.o"
expect_no_overlap "build/?.o" "build/ab.o"

echo "=== Mixed complex ==="
expect_overlap "**/Makefile" "src/Makefile"
expect_overlap "**/Makefile" "**/Makefile"
expect_no_overlap "**/Makefile" "**/README.md"
expect_overlap "build/{debug,release}/*.o" "build/debug/*.o"
expect_no_overlap "build/{debug,release}/*.o" "build/staging/*.o"

echo "=== Extended globs (unsupported -- conservative fallback) ==="
# These all produce GROUP states in the NFA.
# The tool cannot determine precise overlap, so it conservatively says "overlap"
# and prints a warning to stderr.
expect_overlap_with_warning() {
    local stderr_out
    stderr_out=$("$TOOL" "$1" "$2" 2>&1 1>/dev/null)
    local status=$?
    if [ $status -eq 0 ]; then
        ((PASS++))
    else
        ((FAIL++))
        echo "FAIL: expected overlap (conservative): '$1'  vs  '$2'"
    fi
    matched=$(echo "$stderr_out" | /usr/bin/grep "warning")
    if [ -n "$matched" ]; then
        ((PASS++))
    else
        ((FAIL++))
        echo "FAIL: expected warning for:             '$1'  vs  '$2'  (got: '$stderr_out')"
    fi
}

# *(pattern) - zero or more matches
expect_overlap_with_warning '*(foo|bar).o' 'baz.o'

# +(pattern) - one or more matches
expect_overlap_with_warning '+(foo).o' 'bar.o'

# ?(pattern) - zero or one match
expect_overlap_with_warning '?(foo).o' 'bar.o'

# @(pattern) - exactly one match
expect_overlap_with_warning '@(foo|bar).o' 'baz.o'

# !(pattern) - negation
expect_overlap_with_warning '!(foo).o' 'bar.o'

# GROUP is conservative for its segment, but other segments can still
# prove no overlap. Here *.o vs *.h resolves it despite the GROUP warning.
expect_no_overlap 'build/*(src|lib)/*.o' 'build/test/*.h'

echo "=== Edge cases ==="
# Empty segments (single-component patterns)
expect_overlap '*.o' '*.o'
expect_overlap '*' 'anything'
expect_no_overlap '*' ''

# Globstar only
expect_overlap '**' '**'
expect_overlap '**' 'any/path/at/all.txt'
expect_overlap '**/*.o' '**/*.o'
expect_no_overlap '**/*.o' '**/*.h'

# Trailing globstar
expect_overlap 'build/**' 'build/foo/bar.o'
expect_no_overlap 'build/**' 'src/foo.o'

# Leading globstar
expect_overlap '**/*.o' 'build/foo.o'
expect_overlap '**/*.o' 'deeply/nested/path/foo.o'

# Multiple globstars
expect_overlap '**/*.o' 'build/**/*.o'
expect_no_overlap '**/*.o' 'build/**/*.h'

# Adjacent segments with wildcards
expect_overlap 'build/*/foo.o' 'build/debug/foo.o'
expect_no_overlap 'build/*/foo.o' 'build/debug/bar.o'
expect_overlap 'build/[a-z]*/*.o' 'build/debug/main.o'

# Nested braces
expect_overlap '*.{o,{lib,a}}' '*.lib'
expect_overlap '*.{o,{lib,a}}' '*.a'
expect_no_overlap '*.{o,{lib,a}}' '*.h'

# Single char vs range
expect_overlap 'build/[a-z].o' 'build/[x-z].o'
expect_no_overlap 'build/[a-c].o' 'build/[x-z].o'

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAIL
