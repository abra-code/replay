// The generated variant for aarch64 CPUs with CRC and PMULL but without EOR3 (Graviton2,
// Ampere Altra, Raspberry Pi 5), under its own name for run-time selection
// (crc32c_variants.h). The target attributes let it compile for plain ARMv8.0.

#include "crc32c_variants.h"

#if CRC32C_VARIANTS_ENABLED && (defined(__arm64__) || defined(__aarch64__))
	#include <stddef.h>
	#include <stdint.h>
	#include <arm_acle.h>
	#include <arm_neon.h>
	#define crc32_impl crc32c_neon
	#pragma clang attribute push (__attribute__((target("crc,aes"))), apply_to = function)
	#include "ab_neon_crc32c_v3s4x2e_v2.c"
	#pragma clang attribute pop
	#undef crc32_impl
#endif
