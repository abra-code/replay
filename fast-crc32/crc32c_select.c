// Which CRC32C variant this CPU can run (crc32c_variants.h).

#include "crc32c_variants.h"

#if CRC32C_VARIANTS_ENABLED

#if defined(__arm64__) || defined(__aarch64__)

#if defined(__linux__)
	#include <sys/auxv.h>
	// The bits of AT_HWCAP (asm/hwcap.h), defined here in case the headers are older.
	#ifndef HWCAP_PMULL
		#define HWCAP_PMULL (1ul << 4)
	#endif
	#ifndef HWCAP_CRC32
		#define HWCAP_CRC32 (1ul << 7)
	#endif
	#ifndef HWCAP_SHA3
		#define HWCAP_SHA3 (1ul << 17)
	#endif
#elif defined(__APPLE__)
	#include <sys/sysctl.h>
#endif

#if defined(__APPLE__)
static int apple_has(const char *name)
{
	int value = 0;
	size_t size = sizeof(value);
	if (sysctlbyname(name, &value, &size, NULL, 0) != 0)
		return 0;
	return value != 0;
}
#endif

unsigned crc32c_cpu_features(void)
{
	unsigned features = 0;
#if defined(__linux__)
	unsigned long hwcap = getauxval(AT_HWCAP);
	if (hwcap & HWCAP_CRC32)
		features |= CRC32C_FEATURE_CRC;
	if (hwcap & HWCAP_PMULL)
		features |= CRC32C_FEATURE_CLMUL;
	if (hwcap & HWCAP_SHA3)
		features |= CRC32C_FEATURE_EOR3;
#elif defined(__APPLE__)
	// Only reached in the test build (CRC32C_ALL_VARIANTS); Apple silicon has all three.
	if (apple_has("hw.optional.armv8_crc32"))
		features |= CRC32C_FEATURE_CRC;
	if (apple_has("hw.optional.arm.FEAT_PMULL"))
		features |= CRC32C_FEATURE_CLMUL;
	if (apple_has("hw.optional.arm.FEAT_SHA3"))
		features |= CRC32C_FEATURE_EOR3;
#endif
	// Elsewhere no detection: the portable variant, which is always correct.
	return features;
}

crc32c_fn crc32c_select(unsigned features)
{
	unsigned crc_clmul = CRC32C_FEATURE_CRC | CRC32C_FEATURE_CLMUL;
	if ((features & (crc_clmul | CRC32C_FEATURE_EOR3)) == (crc_clmul | CRC32C_FEATURE_EOR3))
		return crc32c_neon_eor3;
	if ((features & crc_clmul) == crc_clmul)
		return crc32c_neon;
	if (features & CRC32C_FEATURE_CRC)
		return crc32c_hw;
	return crc32c_portable;
}

const char *crc32c_variant_name(crc32c_fn fn)
{
	if (fn == crc32c_neon_eor3)
		return "neon_eor3";
	if (fn == crc32c_neon)
		return "neon";
	if (fn == crc32c_hw)
		return "hw";
	if (fn == crc32c_portable)
		return "portable";
	return "unknown";
}

#elif defined(__x86_64__)

unsigned crc32c_cpu_features(void)
{
	unsigned features = 0;
	__builtin_cpu_init();
	if (__builtin_cpu_supports("sse4.2"))
		features |= CRC32C_FEATURE_CRC;
	if (__builtin_cpu_supports("pclmul"))
		features |= CRC32C_FEATURE_CLMUL;
	return features;
}

crc32c_fn crc32c_select(unsigned features)
{
	unsigned crc_clmul = CRC32C_FEATURE_CRC | CRC32C_FEATURE_CLMUL;
	if ((features & crc_clmul) == crc_clmul)
		return crc32c_sse;
	if (features & CRC32C_FEATURE_CRC)
		return crc32c_hw;
	return crc32c_portable;
}

const char *crc32c_variant_name(crc32c_fn fn)
{
	if (fn == crc32c_sse)
		return "sse";
	if (fn == crc32c_hw)
		return "hw";
	if (fn == crc32c_portable)
		return "portable";
	return "unknown";
}

#else
	#error Unsupported architecture
#endif

#endif // CRC32C_VARIANTS_ENABLED
