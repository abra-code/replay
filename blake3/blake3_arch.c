#if defined( __arm64__ )
	#include "blake3_neon.c"
#elif defined( __x86_64__ )
	#include "blake3_sse2.c"
#else
	#error Unsupported architecure
#endif
