#if defined( __arm64__ )
	#include "ab_neon_eor3_crc32c_v9s3x2e_s3.c"
#elif defined( __x86_64__ )
    #include <crc32intrin.h>
	#include "ab_sse_crc32c_v4s3x3k4096e.c"
#else
	#error Unsupported architecure
#endif
