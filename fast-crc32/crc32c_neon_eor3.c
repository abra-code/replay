// The generated EOR3 variant under its own name, for run-time selection (crc32c_variants.h).
// Needs CRC, PMULL and EOR3; the target attributes let it compile for plain ARMv8.0.

#include "crc32c_variants.h"

#if CRC32C_VARIANTS_ENABLED && (defined(__arm64__) || defined(__aarch64__))
	#include <stddef.h>
	#include <stdint.h>
	#include <arm_acle.h>
	#include <arm_neon.h>
	#define crc32_impl crc32c_neon_eor3
	#pragma clang attribute push (__attribute__((target("crc,aes,sha3"))), apply_to = function)
	#include "ab_neon_eor3_crc32c_v9s3x2e_s3.c"
	#pragma clang attribute pop
	#undef crc32_impl
#endif
