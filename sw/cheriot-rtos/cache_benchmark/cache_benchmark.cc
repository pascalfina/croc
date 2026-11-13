// SPDX-License-Identifier: SHL-0.51

#include <compartment.h>
#include <debug.hh>
#include <fail-simulator-on-error.h>
#include <riscvreg.h>

using Debug = ConditionalDebug<true, "Cache benchmark">;

namespace
{
	constexpr size_t RegionBytes = 256 * 1024;
	constexpr size_t Words       = RegionBytes / sizeof(uint32_t);

	constexpr size_t   Accesses     = 4096;
	constexpr size_t   Strides[]    = {4, 16, 64, 256};
	constexpr size_t   WorkingSets[] = {1024, 4096, 16384, Words};
	constexpr size_t   Nodes        = 4096;
	constexpr size_t   NodeWords    = 8;
	constexpr size_t   CapSlots     = 4096;
	constexpr size_t   CapWords     = CapSlots * sizeof(void *) / sizeof(uint32_t);
	constexpr size_t   ChaseSteps   = 2 * Nodes;
	constexpr uint32_t CodeRounds   = 8;

	static_assert((Words & (Words - 1)) == 0);
	static_assert(Nodes * NodeWords + CapWords <= Words);

	const char *const PhaseNames[] = {
	  "init", "stream", "copy", "stride", "random", "chase", "capabilities", "code"};
	constexpr size_t NumPhases = sizeof(PhaseNames) / sizeof(PhaseNames[0]);

	constexpr uint32_t next_index(uint32_t index, uint32_t count)
	{
		return (index * 1664525u + 1013904223u) & (count - 1);
	}

	uint32_t xorshift(uint32_t &state)
	{
		state ^= state << 13;
		state ^= state >> 17;
		state ^= state << 5;
		return state;
	}

	constexpr uint32_t mix(uint32_t x, uint32_t seed, uint32_t n)
	{
		x ^= seed * 0x9e3779b1u + n * 0x85ebca6bu;
		x *= 0x01000193u;
		return x ^ (x >> (9 + n % 7));
	}

#define STEP(n) x = mix(x, Seed, (n));
#define STEP4(n) STEP(n) STEP(n + 1) STEP(n + 2) STEP(n + 3)
#define STEP16(n) STEP4(n) STEP4(n + 4) STEP4(n + 8) STEP4(n + 12)

	template<uint32_t Seed>
	__attribute__((noinline)) uint32_t code_block(uint32_t x)
	{
		STEP16(0) STEP16(16) STEP16(32) STEP16(48)
		return x;
	}

#undef STEP16
#undef STEP4
#undef STEP

	using CodeBlock = uint32_t (*)(uint32_t);
	CodeBlock const CodeBlocks[] = {code_block<1>,
	                                code_block<2>,
	                                code_block<3>,
	                                code_block<4>,
	                                code_block<5>,
	                                code_block<6>,
	                                code_block<7>,
	                                code_block<8>};
	constexpr size_t NumCodeBlocks = sizeof(CodeBlocks) / sizeof(CodeBlocks[0]);

	void phase_init(volatile uint32_t *w)
	{
		for (size_t i = 0; i < Words; i++)
		{
			w[i] = i * 0x9e3779b1u;
		}
	}

	uint32_t phase_stream(volatile uint32_t *w)
	{
		uint32_t sum = 0;
		for (size_t i = 0; i < Words; i++)
		{
			sum += w[i];
		}
		return sum;
	}

	void phase_copy(volatile uint32_t *w)
	{
		for (size_t i = 0; i < Words / 2; i++)
		{
			w[Words / 2 + i] = w[i] ^ i;
		}
	}

	void phase_stride(volatile uint32_t *w)
	{
		for (size_t stride : Strides)
		{
			for (size_t i = 0; i < Accesses; i++)
			{
				w[(i * stride) & (Words - 1)] += i;
			}
		}
	}

	void phase_random(volatile uint32_t *w)
	{
		uint32_t state = 0x2545f491u;
		for (size_t workingSet : WorkingSets)
		{
			for (size_t i = 0; i < Accesses; i++)
			{
				w[xorshift(state) & (workingSet - 1)] += i;
			}
		}
	}

	uint32_t phase_chase(volatile uint32_t *w)
	{
		for (uint32_t n = 0; n < Nodes; n++)
		{
			w[n * NodeWords] = next_index(n, Nodes);
		}
		uint32_t n = 0;
		for (size_t step = 0; step < ChaseSteps; step++)
		{
			n = w[n * NodeWords];
		}
		return n;
	}

	uint32_t phase_capabilities(volatile uint32_t *w)
	{
		auto *slots = reinterpret_cast<void *volatile *>(w + Nodes * NodeWords);
		for (uint32_t s = 0; s < CapSlots; s++)
		{
			slots[s] = const_cast<void **>(&slots[next_index(s, CapSlots)]);
		}
		void *volatile *slot = slots;
		for (size_t step = 0; step < ChaseSteps; step++)
		{
			slot = static_cast<void *volatile *>(*slot);
		}
		return static_cast<uint32_t>(slot - slots);
	}

	uint32_t phase_code()
	{
		uint32_t x = 1;
		for (uint32_t round = 0; round < CodeRounds; round++)
		{
			for (size_t b = 0; b < NumCodeBlocks; b++)
			{
				x = CodeBlocks[(3 * b + round) % NumCodeBlocks](x);
			}
		}
		return x;
	}
} // namespace

int __cheri_compartment("benchmark") benchmark()
{
	uint64_t marks[NumPhases + 1];
	marks[0] = rdcycle64();

	volatile uint32_t *w = MMIO_CAPABILITY_WITH_PERMISSIONS(
	  uint32_t, cache_benchmark_memory, true, true, true, true, true);
	uint32_t checksum = 0;

	phase_init(w);
	marks[1] = rdcycle64();
	checksum += phase_stream(w);
	marks[2] = rdcycle64();
	phase_copy(w);
	marks[3] = rdcycle64();
	phase_stride(w);
	marks[4] = rdcycle64();
	phase_random(w);
	marks[5] = rdcycle64();
	checksum += phase_chase(w);
	marks[6] = rdcycle64();
	checksum += phase_capabilities(w);
	marks[7] = rdcycle64();
	checksum += phase_code();
	marks[8] = rdcycle64();

	checksum += phase_stream(w);

	for (size_t p = 0; p < NumPhases; p++)
	{
		Debug::log("BENCH {} {}",
		           PhaseNames[p],
		           static_cast<int32_t>(marks[p + 1] - marks[p]));
	}
	Debug::log("BENCH total {}", static_cast<int32_t>(marks[NumPhases] - marks[0]));
	Debug::log("BENCH checksum {}", checksum);
	return 0;
}
