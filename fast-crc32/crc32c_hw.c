// CRC32C with the CPU's CRC instruction alone, 8 bytes per instruction. For CPUs that
// have it but no carryless multiply, which every faster variant needs to combine its
// parallel streams (on aarch64 the Raspberry Pi 4, for example). The target attributes
// let it compile for plain ARMv8.0 or baseline x86-64.

#include "crc32c_variants.h"

#if CRC32C_VARIANTS_ENABLED

#include <string.h>

#if defined(__arm64__) || defined(__aarch64__)
	#include <arm_acle.h>
	#define CRC32C_HW_TARGET __attribute__((target("crc")))
	#define CRC32C_HW_BYTE(crc, b) __crc32cb((crc), (b))
	#define CRC32C_HW_WORD(crc, w) __crc32cd((crc), (w))
#elif defined(__x86_64__)
	#include <nmmintrin.h>
	#define CRC32C_HW_TARGET __attribute__((target("sse4.2")))
	#define CRC32C_HW_BYTE(crc, b) _mm_crc32_u8((crc), (b))
	#define CRC32C_HW_WORD(crc, w) (uint32_t)_mm_crc32_u64((crc), (w))
#else
	#error Unsupported architecture
#endif

CRC32C_HW_TARGET
uint32_t crc32c_hw(uint32_t crc0, const char *buf, size_t len)
{
	uint32_t crc = ~crc0;
	const unsigned char *p = (const unsigned char *)buf;

	// Bytes up to an 8-byte boundary, then whole words, then the rest. memcpy keeps the
	// word loads free of alignment and aliasing assumptions; it compiles to one load.
	while (len > 0 && ((uintptr_t)p & 7u) != 0)
	{
		crc = CRC32C_HW_BYTE(crc, *p);
		p++;
		len--;
	}
	while (len >= 8)
	{
		uint64_t word;
		memcpy(&word, p, sizeof(word));
		crc = CRC32C_HW_WORD(crc, word);
		p += 8;
		len -= 8;
	}
	while (len > 0)
	{
		crc = CRC32C_HW_BYTE(crc, *p);
		p++;
		len--;
	}
	return ~crc;
}

#endif // CRC32C_VARIANTS_ENABLED
