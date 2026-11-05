// Checks every CRC32C variant this CPU can run against the portable one and against
// published check values, then checks which variant each set of CPU features selects.
// Built and run by test_crc32c_variants.sh, with fast-crc32/*.c and CRC32C_ALL_VARIANTS.

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "crc32c_variants.h"

uint32_t crc32_impl(uint32_t crc0, const char *buf, size_t len);

static int s_pass = 0;
static int s_fail = 0;

static void check(int condition, const char *what, const char *variant, size_t len, size_t offset,
	uint32_t got, uint32_t expected)
{
	if (condition)
	{
		s_pass++;
		return;
	}
	s_fail++;
	if (s_fail <= 20)
		printf("  FAIL: %s %s len=%zu offset=%zu: 0x%08x, expected 0x%08x\n",
			variant, what, len, offset, got, expected);
}

typedef struct
{
	crc32c_fn fn;
	unsigned needs;
} variant_t;

static const variant_t kVariants[] =
{
#if defined(__arm64__) || defined(__aarch64__)
	{ crc32c_neon_eor3, CRC32C_FEATURE_CRC | CRC32C_FEATURE_CLMUL | CRC32C_FEATURE_EOR3 },
	{ crc32c_neon,      CRC32C_FEATURE_CRC | CRC32C_FEATURE_CLMUL },
#elif defined(__x86_64__)
	{ crc32c_sse,       CRC32C_FEATURE_CRC | CRC32C_FEATURE_CLMUL },
#endif
	{ crc32c_hw,        CRC32C_FEATURE_CRC },
	{ crc32c_portable,  0 },
};

// Check values: "123456789" is the standard CRC catalog check; the 32-byte patterns are
// RFC 3720 (iSCSI) appendix B.4.
static void check_known_values(crc32c_fn fn, const char *name)
{
	unsigned char block[32];
	uint32_t got = fn(0, "123456789", 9);
	check(got == 0xE3069283u, "check value", name, 9, 0, got, 0xE3069283u);
	got = fn(0, "", 0);
	check(got == 0u, "empty input", name, 0, 0, got, 0u);

	memset(block, 0x00, sizeof(block));
	got = fn(0, (const char *)block, sizeof(block));
	check(got == 0x8A9136AAu, "32 zero bytes", name, 32, 0, got, 0x8A9136AAu);
	memset(block, 0xFF, sizeof(block));
	got = fn(0, (const char *)block, sizeof(block));
	check(got == 0x62A8AB43u, "32 0xFF bytes", name, 32, 0, got, 0x62A8AB43u);
	for (int i = 0; i < 32; i++)
		block[i] = (unsigned char)i;
	got = fn(0, (const char *)block, sizeof(block));
	check(got == 0x46DD794Eu, "32 ascending bytes", name, 32, 0, got, 0x46DD794Eu);
	for (int i = 0; i < 32; i++)
		block[i] = (unsigned char)(31 - i);
	got = fn(0, (const char *)block, sizeof(block));
	check(got == 0x113FDB5Cu, "32 descending bytes", name, 32, 0, got, 0x113FDB5Cu);
}

#define BUFFER_SIZE (300000 + 64)
static unsigned char s_buffer[BUFFER_SIZE];

static void fill_buffer(void)
{
	uint64_t x = 0x9E3779B97F4A7C15ull; // xorshift64, fixed seed: the same data every run
	for (size_t i = 0; i < BUFFER_SIZE; i++)
	{
		x ^= x << 13;
		x ^= x >> 7;
		x ^= x << 17;
		s_buffer[i] = (unsigned char)(x >> 32);
	}
}

// Lengths around every block size the variants use (16 to 4096 bytes, and the larger
// outer blocks), plus a few large ones.
static const size_t kLengths[] =
{
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 31, 32, 33, 47, 48, 63, 64, 65, 95, 96, 127, 128,
	129, 143, 144, 191, 192, 255, 256, 257, 383, 384, 511, 512, 513, 1023, 1024, 1025, 2047,
	2048, 4095, 4096, 4097, 8191, 8192, 12288, 12289, 65535, 65536, 65537, 100003, 300000,
};

static void check_against_portable(crc32c_fn fn, const char *name)
{
	for (size_t li = 0; li < sizeof(kLengths) / sizeof(kLengths[0]); li++)
	{
		size_t len = kLengths[li];
		for (size_t offset = 0; offset < 16; offset++)
		{
			const char *p = (const char *)s_buffer + offset;
			uint32_t expected = crc32c_portable(0, p, len);
			uint32_t got = fn(0, p, len);
			check(got == expected, "vs portable", name, len, offset, got, expected);

			// Continuing a checksum: two calls over a split give the one-call result.
			size_t split = len / 3;
			uint32_t first = fn(0, p, split);
			uint32_t chained = fn(first, p + split, len - split);
			check(chained == expected, "chained", name, len, offset, chained, expected);
		}
	}
}

static void check_selection(void)
{
	struct { unsigned features; const char *expected; } cases[] =
	{
#if defined(__arm64__) || defined(__aarch64__)
		{ CRC32C_FEATURE_CRC | CRC32C_FEATURE_CLMUL | CRC32C_FEATURE_EOR3, "neon_eor3" },
		{ CRC32C_FEATURE_CRC | CRC32C_FEATURE_CLMUL,                       "neon" },
		{ CRC32C_FEATURE_CRC | CRC32C_FEATURE_EOR3,                        "hw" },
		{ CRC32C_FEATURE_CLMUL | CRC32C_FEATURE_EOR3,                      "portable" },
#elif defined(__x86_64__)
		{ CRC32C_FEATURE_CRC | CRC32C_FEATURE_CLMUL,                       "sse" },
		{ CRC32C_FEATURE_CLMUL,                                            "portable" },
#endif
		{ CRC32C_FEATURE_CRC,                                              "hw" },
		{ 0,                                                               "portable" },
	};
	for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
	{
		const char *got = crc32c_variant_name(crc32c_select(cases[i].features));
		if (strcmp(got, cases[i].expected) == 0)
		{
			s_pass++;
		}
		else
		{
			s_fail++;
			printf("  FAIL: features 0x%x select %s, expected %s\n", cases[i].features, got, cases[i].expected);
		}
	}
}

int main(void)
{
	unsigned features = crc32c_cpu_features();
	crc32c_fn chosen = crc32c_select(features);
	printf("CPU features 0x%x, selected variant: %s\n", features, crc32c_variant_name(chosen));

	// Where the features are known, detection that under-reports would skip variants and
	// still pass, so check it: every Apple silicon Mac has all three, and Rosetta offers
	// SSE4.2 and PCLMULQDQ.
#if defined(__APPLE__)
	#if defined(__arm64__) || defined(__aarch64__)
	unsigned known = CRC32C_FEATURE_CRC | CRC32C_FEATURE_CLMUL | CRC32C_FEATURE_EOR3;
	#else
	unsigned known = CRC32C_FEATURE_CRC | CRC32C_FEATURE_CLMUL;
	#endif
	if (features == known)
	{
		s_pass++;
	}
	else
	{
		s_fail++;
		printf("  FAIL: detected CPU features 0x%x, expected 0x%x on this Mac\n", features, known);
	}
#endif

	fill_buffer();
	for (size_t i = 0; i < sizeof(kVariants) / sizeof(kVariants[0]); i++)
	{
		const char *name = crc32c_variant_name(kVariants[i].fn);
		if ((features & kVariants[i].needs) != kVariants[i].needs)
		{
			printf("  skipped: %s (this CPU lacks its instructions)\n", name);
			continue;
		}
		int before = s_fail;
		check_known_values(kVariants[i].fn, name);
		check_against_portable(kVariants[i].fn, name);
		printf("  %s: %s\n", name, s_fail == before ? "ok" : "FAILED");
	}

	// The entry point the tools call: the selected variant on Linux, the vendored one on Apple.
	int before = s_fail;
	check_known_values(crc32_impl, "crc32_impl");
	check_against_portable(crc32_impl, "crc32_impl");
	printf("  crc32_impl: %s\n", s_fail == before ? "ok" : "FAILED");

	check_selection();

	printf("Passed: %d  Failed: %d\n", s_pass, s_fail);
	return s_fail == 0 ? 0 : 1;
}
