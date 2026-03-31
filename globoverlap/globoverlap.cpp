#include "GlobOverlap.h"
#include <iostream>

// ============================================================================
// CLI test tool for glob pattern overlap detection.
// Uses replay::patterns_overlap() from GlobOverlap.h.
// See test_overlap.sh for the test suite.
// ============================================================================

int main(int argc, const char *argv[]) {
    if (argc != 3) {
        std::cerr << "usage: " << argv[0] << " <pattern1> <pattern2>\n";
        return 2;
    }
    bool overlap = globoverlap::patterns_overlap(argv[1], argv[2]);
    std::cout << (overlap ? "overlap" : "no overlap") << '\n';
    return overlap ? 0 : 1;
}
