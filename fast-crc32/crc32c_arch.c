// Picks the CRC32C implementation for the target architecture.
//
// The vendored files use CPU instructions beyond each architecture's baseline, so they are
// compiled with function target attributes rather than command-line flags: SwiftPM has no
// per-architecture flags, and Linux clang targets plain ARMv8.0 or x86-64 by default.
// (Xcode also passes -mcrc32 -mpclmul for x86_64 in FastCrc32TargetCommon.xcconfig.)
// The system headers are included first, outside the attribute region.
//
// Known gap (plan Phase 1a): there is no run-time CPU check and no fallback yet, so on
// aarch64 a CPU without the SHA3 extension (EOR3), such as AWS Graviton2 or Raspberry Pi,
// stops with an illegal instruction. Every Apple silicon Mac has it.

#if defined( __arm64__ ) || defined( __aarch64__ )
	#include <stddef.h>
	#include <stdint.h>
	#include <arm_acle.h>
	#include <arm_neon.h>
	#pragma clang attribute push (__attribute__((target("crc,aes,sha3"))), apply_to = function)
	#include "ab_neon_eor3_crc32c_v9s3x2e_s3.c"
	#pragma clang attribute pop
#elif defined( __x86_64__ )
	#include <stddef.h>
	#include <stdint.h>
	#include <nmmintrin.h>
	#include <wmmintrin.h>
	#include <crc32intrin.h>
	#pragma clang attribute push (__attribute__((target("crc32,sse4.2,pclmul"))), apply_to = function)
	#include "ab_sse_crc32c_v4s3x3k4096e.c"
	#pragma clang attribute pop
#else
	#error Unsupported architecure
#endif
