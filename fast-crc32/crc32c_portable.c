// CRC32C without special instructions: a byte at a time through a 256-entry table.
// For CPUs without CRC instructions (aarch64 ARMv8.0 without the optional CRC32 extension,
// x86_64 before SSE4.2); also the reference the test compares every other variant with.

#include "crc32c_variants.h"

#if CRC32C_VARIANTS_ENABLED

#include <pthread.h>

// CRC32C (Castagnoli) polynomial, bit-reversed.
#define CRC32C_POLY_REVERSED 0x82F63B78u

static uint32_t s_table[256];
static pthread_once_t s_table_once = PTHREAD_ONCE_INIT;

static void build_table(void)
{
	for (uint32_t i = 0; i < 256; i++)
	{
		uint32_t crc = i;
		for (int bit = 0; bit < 8; bit++)
			crc = (crc >> 1) ^ ((crc & 1u) ? CRC32C_POLY_REVERSED : 0u);
		s_table[i] = crc;
	}
}

uint32_t crc32c_portable(uint32_t crc0, const char *buf, size_t len)
{
	pthread_once(&s_table_once, build_table);
	uint32_t crc = ~crc0;
	const unsigned char *p = (const unsigned char *)buf;
	for (size_t i = 0; i < len; i++)
		crc = s_table[(crc ^ p[i]) & 0xFFu] ^ (crc >> 8);
	return ~crc;
}

#endif // CRC32C_VARIANTS_ENABLED
