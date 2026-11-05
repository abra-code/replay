// The generated SSE4.2 + PCLMULQDQ variant under its own name, for run-time selection
// (crc32c_variants.h). The target attributes let it compile for baseline x86-64.

#include "crc32c_variants.h"

#if CRC32C_VARIANTS_ENABLED && defined(__x86_64__)
	#include <stddef.h>
	#include <stdint.h>
	#include <nmmintrin.h>
	#include <wmmintrin.h>
	#include <crc32intrin.h>
	#define crc32_impl crc32c_sse
	#pragma clang attribute push (__attribute__((target("crc32,sse4.2,pclmul"))), apply_to = function)
	#include "ab_sse_crc32c_v4s3x3k4096e.c"
	#pragma clang attribute pop
	#undef crc32_impl
#endif
