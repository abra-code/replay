// Provides crc32_impl, the CRC32C entry point the tools call (FileHashing.h).
//
// Apple platforms: the vendored variant for the architecture, called directly. Every
// Apple silicon Mac has CRC, PMULL and EOR3, and every Intel Mac that runs a current macOS
// has SSE4.2 and PCLMULQDQ, so there is nothing to choose.
//
// Elsewhere (Linux): the fastest variant this CPU can run, chosen on the first call
// (crc32c_variants.h, crc32c_select.c). On aarch64 that keeps the EOR3 variant where the
// SHA3 extension exists (Graviton3 and newer) and avoids an illegal instruction where it
// does not (Graviton2, Ampere Altra, Raspberry Pi).
//
// The vendored files use CPU instructions beyond each architecture's baseline, so they are
// compiled with function target attributes rather than command-line flags: SwiftPM has no
// per-architecture flags, and Linux clang targets plain ARMv8.0 or x86-64 by default.
// (Xcode also passes -mcrc32 -mpclmul for x86_64 in FastCrc32TargetCommon.xcconfig.)
// The system headers are included first, outside the attribute region.

#if defined(__APPLE__)

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

#else // not Apple: choose at run time

#include <stdatomic.h>
#include "crc32c_variants.h"

// Relaxed is enough: every thread that races here stores the same pointer, and what it
// points to is code, which needs no publication. The portable variant guards its own table.
static _Atomic(crc32c_fn) s_crc32c_variant = NULL;

uint32_t crc32_impl(uint32_t crc0, const char *buf, size_t len)
{
	crc32c_fn variant = atomic_load_explicit(&s_crc32c_variant, memory_order_relaxed);
	if (variant == NULL)
	{
		variant = crc32c_select(crc32c_cpu_features());
		atomic_store_explicit(&s_crc32c_variant, variant, memory_order_relaxed);
	}
	return variant(crc0, buf, len);
}

#endif
