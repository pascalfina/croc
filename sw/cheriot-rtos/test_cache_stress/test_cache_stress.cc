// SPDX-License-Identifier: SHL-0.51
//
// Stress test for Croc's HyperRAM-backed caches (8 KiB, two ways, 16-byte
// lines). The heap buffer is twice the D-cache size with four aliases per
// cache set, so accesses constantly miss, evict dirty lines and refill them
// from HyperRAM. Each phase logs its result; a failing phase ends the
// simulation with its phase number as the exit code.

// The 16 KiB buffer and the revocation probes exceed the default 4 KiB quota.
#define MALLOC_QUOTA (24 * 1024)

#include <cheri.hh>
#include <compartment.h>
#include <debug.hh>
#include <fail-simulator-on-error.h>
#include <simulator.h>
#include <stdlib.h>

using Debug = ConditionalDebug<true, "Cache stress">;

namespace
{
	// Cache geometry: each way covers 4 KiB, so addresses 4 KiB apart share a
	// set. Four aliases always exceed the two ways.
	constexpr size_t WayBytes     = 4096;
	constexpr size_t LineBytes    = 16;
	constexpr size_t BufferBytes  = 4 * WayBytes;
	constexpr size_t Aliases      = BufferBytes / WayBytes;
	constexpr size_t Words        = BufferBytes / sizeof(uint32_t);
	constexpr size_t WayWords     = WayBytes / sizeof(uint32_t);
	constexpr size_t WordsPerLine = LineBytes / sizeof(uint32_t);

	// Capabilities occupy 8-byte slots; one capability every 32 bytes leaves
	// the other record of each line and every second line free for copies
	// and revocation probes.
	constexpr size_t SlotBytes = 8;
	constexpr size_t Slots     = BufferBytes / SlotBytes;
	constexpr size_t WaySlots  = WayBytes / SlotBytes;
	constexpr size_t CapStride = 4;

	constexpr uint32_t MaxReports = 8;

	static_assert(Aliases >= 3, "conflict phases need more aliases than ways");
	static_assert((Words & (Words - 1)) == 0, "permute() needs a power of two");

	uint32_t errors;

	uint32_t pattern(uint32_t index, uint32_t round)
	{
		uint32_t x = index * 0x9e3779b1u + (round + 1) * 0x7f4a7c15u;
		x ^= x >> 15;
		x *= 0x2c1b3c6du;
		x ^= x >> 12;
		return x;
	}

	// Bijective word order: an odd multiplier modulo a power of two.
	size_t permute(size_t index, uint32_t round)
	{
		return (index * (2 * round + 0x2b5) + round * 0x3c1) & (Words - 1);
	}

	void check(const char *what, size_t index, uint32_t expected, uint32_t actual)
	{
		if ((expected != actual) && (errors++ < MaxReports))
		{
			Debug::log(
			  "{}: index {} expected {} got {}", what, index, expected, actual);
		}
	}

	void check_cap(const char *what, size_t index, void *expected, void *actual)
	{
		if (!__builtin_cheri_equal_exact(expected, actual) &&
		    (errors++ < MaxReports))
		{
			Debug::log(
			  "{}: index {} expected {} got {}", what, index, expected, actual);
		}
	}

	// A capability whose bits survived but whose tag must have been cleared.
	void check_cleared(const char *what,
	                   size_t      index,
	                   ptraddr_t   expectedAddress,
	                   void       *actual)
	{
		bool ok = !__builtin_cheri_tag_get(actual) &&
		          (__builtin_cheri_address_get(actual) == expectedAddress);
		if (!ok && (errors++ < MaxReports))
		{
			Debug::log("{}: index {} expected untagged address {} got {}",
			           what,
			           index,
			           expectedAddress,
			           actual);
		}
	}

	void finish_phase(uint32_t phase, const char *name)
	{
		if (errors != 0)
		{
			Debug::log("FAIL phase {} ({}): {} mismatches", phase, name, errors);
			simulation_exit(phase);
		}
		Debug::log("phase {} ({}) passed", phase, name);
	}

	// Phase 1: whole-buffer passes. Verification starts at lines that were
	// evicted dirty while the rest of the buffer was written.
	void phase_sequential(volatile uint32_t *words)
	{
		for (uint32_t round = 0; round < 2; round++)
		{
			for (size_t i = 0; i < Words; i++)
			{
				words[i] = pattern(i, round);
			}
			if (round == 0)
			{
				for (size_t i = 0; i < Words; i++)
				{
					check("sequential", i, pattern(i, round), words[i]);
				}
			}
			else
			{
				for (size_t i = Words; i-- > 0;)
				{
					check("sequential-reverse", i, pattern(i, round), words[i]);
				}
			}
		}
	}

	// Phase 2: the same set in all aliases back to back, so every new line
	// evicts a dirty line, followed by word-granular ping-pong in one set.
	void phase_conflict(volatile uint32_t *words)
	{
		constexpr uint32_t Round   = 2;
		constexpr size_t   PingSet = 8;

		for (size_t line = 0; line < WayWords; line += WordsPerLine)
		{
			for (size_t alias = 0; alias < Aliases; alias++)
			{
				for (size_t w = 0; w < WordsPerLine; w++)
				{
					size_t i = alias * WayWords + line + w;
					words[i] = pattern(i, Round);
				}
			}
		}
		for (size_t line = 0; line < WayWords; line += WordsPerLine)
		{
			for (size_t alias = Aliases; alias-- > 0;)
			{
				for (size_t w = 0; w < WordsPerLine; w++)
				{
					size_t i = alias * WayWords + line + w;
					check("conflict", i, pattern(i, Round), words[i]);
				}
			}
		}
		for (uint32_t rep = 0; rep < 64; rep++)
		{
			size_t word = PingSet * WordsPerLine + rep % WordsPerLine;
			for (size_t alias = 0; alias < Aliases; alias++)
			{
				size_t i = alias * WayWords + word;
				words[i] = pattern(i, Round + 1 + rep);
			}
			for (size_t alias = 0; alias < Aliases; alias++)
			{
				size_t i = alias * WayWords + word;
				check("ping-pong", i, pattern(i, Round + 1 + rep), words[i]);
			}
		}
	}

	// Phase 3: each partial-store pass covers the whole buffer, so its target
	// line was evicted dirty since the previous pass. Every byte/halfword store
	// takes the write-allocate refill and the read-modify-write ECC merge.
	void phase_partial(volatile uint32_t *words)
	{
		auto *bytes  = reinterpret_cast<volatile uint8_t *>(words);
		auto *halves = reinterpret_cast<volatile uint16_t *>(words);
		constexpr uint32_t Old = 3, Fresh = 4, FreshHalf = 5;

		for (size_t i = 0; i < Words; i++)
		{
			words[i] = pattern(i, Old);
		}
		for (size_t i = 0; i < Words; i++)
		{
			bytes[4 * i + 3] = pattern(i, Fresh) >> 24;
		}
		for (size_t i = 0; i < Words; i++)
		{
			bytes[4 * i + 1] = pattern(i, Fresh) >> 8;
		}
		// Overwrites byte 1 again and byte 0 for the first time; byte 2 keeps
		// its old value through all three merges.
		for (size_t i = 0; i < Words; i++)
		{
			halves[2 * i] = pattern(i, FreshHalf);
		}
		for (size_t i = 0; i < Words; i++)
		{
			uint32_t expected = (pattern(i, FreshHalf) & 0x0000ffff) |
			                    (pattern(i, Old) & 0x00ff0000) |
			                    (pattern(i, Fresh) & 0xff000000);
			check("partial", i, expected, words[i]);
		}
	}

	void store_mixed(volatile uint32_t *words, size_t i, uint32_t value, uint32_t how)
	{
		auto *bytes  = reinterpret_cast<volatile uint8_t *>(words);
		auto *halves = reinterpret_cast<volatile uint16_t *>(words);
		switch (how & 3)
		{
			case 0:
				words[i] = value;
				break;
			case 1:
				halves[2 * i + 1] = value >> 16;
				halves[2 * i]     = value;
				break;
			case 2:
				bytes[4 * i + 3] = value >> 24;
				bytes[4 * i + 1] = value >> 8;
				bytes[4 * i]     = value;
				bytes[4 * i + 2] = value >> 16;
				break;
			default:
				// A stale full word repaired by partial stores.
				words[i]         = ~value;
				halves[2 * i]    = value;
				bytes[4 * i + 2] = value >> 16;
				bytes[4 * i + 3] = value >> 24;
				break;
		}
	}

	uint32_t load_mixed(volatile uint32_t *words, size_t i, uint32_t how)
	{
		auto *bytes  = reinterpret_cast<volatile uint8_t *>(words);
		auto *halves = reinterpret_cast<volatile uint16_t *>(words);
		switch (how & 3)
		{
			case 0:
				return words[i];
			case 1:
				return uint32_t{halves[2 * i]} | (uint32_t{halves[2 * i + 1]} << 16);
			case 2:
				return uint32_t{bytes[4 * i]} | (uint32_t{bytes[4 * i + 1]} << 8) |
				       (uint32_t{bytes[4 * i + 2]} << 16) |
				       (uint32_t{bytes[4 * i + 3]} << 24);
			default:
				return uint32_t{halves[2 * i]} | (uint32_t{bytes[4 * i + 2]} << 16) |
				       (uint32_t{bytes[4 * i + 3]} << 24);
		}
	}

	// Phase 4: pseudo-random word order with random store and load widths.
	void phase_mixed(volatile uint32_t *words)
	{
		constexpr uint32_t Round = 6;

		for (size_t k = 0; k < Words; k++)
		{
			size_t i = permute(k, Round);
			store_mixed(words, i, pattern(i, Round), pattern(k, Round + 1));
		}
		for (size_t k = 0; k < Words; k++)
		{
			size_t i = permute(k, Round + 2);
			check("mixed", i, pattern(i, Round), load_mixed(words, i, pattern(k, Round + 3)));
		}
	}

	void *make_cap(void *buffer, size_t slot)
	{
		auto  *base   = static_cast<char *>(buffer);
		size_t offset = ((slot * 72) % (BufferBytes - 512)) & ~size_t{7};
		// At most 488 bytes, which CHERIoT bounds represent exactly.
		size_t length = 8 + (slot % 61) * 8;
		void  *cap    = __builtin_cheri_bounds_set(base + offset, length);
		if ((slot & 4) != 0)
		{
			cap = __builtin_cheri_perms_and(
			  cap, ~CHERI::PermissionSet{CHERI::Permission::Store}.as_raw());
		}
		return cap;
	}

	size_t cap_slot(size_t position, size_t alias)
	{
		return alias * WaySlots + position;
	}

	// Phase 5: capability stores and loads across conflicting lines, integer
	// overwrites with identical bits (tag must clear) and copies into the
	// other record of a line that already holds a capability.
	void phase_capabilities(void *buffer)
	{
		auto *slots = static_cast<void *volatile *>(buffer);

		for (size_t pos = 0; pos < WaySlots; pos += CapStride)
		{
			for (size_t alias = 0; alias < Aliases; alias++)
			{
				size_t s = cap_slot(pos, alias);
				slots[s] = make_cap(buffer, s);
			}
		}
		for (size_t pos = 0; pos < WaySlots; pos += CapStride)
		{
			for (size_t alias = Aliases; alias-- > 0;)
			{
				size_t s        = cap_slot(pos, alias);
				void  *expected = make_cap(buffer, s);
				check_cap("cap-load", s, expected, slots[s]);
				check("cap-address-word",
				      s,
				      __builtin_cheri_address_get(expected),
				      reinterpret_cast<volatile uint32_t *>(&slots[s])[0]);
			}
		}

		// Groups 1-3 get a second capability in record 1 of the same line.
		// It shares the line and, in the cache SRAM, the packed remainder
		// word with record 0, and must survive the partial overwrite below.
		// Storing all of them first evicts the lines again, so the overwrite
		// refills record 1 from HyperRAM before merging into record 0.
		for (size_t pos = 0; pos < WaySlots; pos += CapStride)
		{
			for (size_t alias = 0; alias < Aliases; alias++)
			{
				size_t s = cap_slot(pos, alias);
				if ((s / CapStride) % 4 != 0)
				{
					slots[s + 1] = make_cap(buffer, s + 1);
				}
			}
		}

		// Group 0 stays intact; groups 1-3 rewrite one word, byte or halfword
		// of record 0 with its own value.
		for (size_t pos = 0; pos < WaySlots; pos += CapStride)
		{
			for (size_t alias = 0; alias < Aliases; alias++)
			{
				size_t s     = cap_slot(pos, alias);
				auto  *word  = reinterpret_cast<volatile uint32_t *>(&slots[s]);
				auto  *byte  = reinterpret_cast<volatile uint8_t *>(&slots[s]);
				auto  *half  = reinterpret_cast<volatile uint16_t *>(&slots[s]);
				switch ((s / CapStride) % 4)
				{
					case 1:
						word[0] = word[0];
						break;
					case 2:
						byte[5] = byte[5];
						break;
					case 3:
						half[1] = half[1];
						break;
					default:
						break;
				}
			}
		}

		// Half a buffer away is the same set; slot + 1 is the second record
		// of a line whose first record holds another intact capability.
		for (size_t pos = 0; pos < WaySlots; pos += CapStride)
		{
			for (size_t alias = 0; alias < Aliases; alias++)
			{
				size_t s = cap_slot(pos, alias);
				if ((s / CapStride) % 4 == 0)
				{
					slots[(s + Slots / 2) % Slots + 1] = slots[s];
				}
			}
		}

		for (size_t pos = 0; pos < WaySlots; pos += CapStride)
		{
			for (size_t alias = Aliases; alias-- > 0;)
			{
				size_t s        = cap_slot(pos, alias);
				void  *expected = make_cap(buffer, s);
				if ((s / CapStride) % 4 == 0)
				{
					check_cap("cap-intact", s, expected, slots[s]);
					size_t copy = (s + Slots / 2) % Slots + 1;
					check_cap("cap-copy", copy, expected, slots[copy]);
				}
				else
				{
					check_cleared("cap-overwritten",
					              s,
					              __builtin_cheri_address_get(expected),
					              slots[s]);
					check_cap("cap-neighbour", s + 1, make_cap(buffer, s + 1), slots[s + 1]);
				}
			}
		}
	}

	void *make_probe(void *object, size_t n)
	{
		return __builtin_cheri_bounds_set(static_cast<char *>(object) + (n % 8) * 8, 8);
	}

	// Phase 6: capabilities to a freed heap object must lose their tag on
	// load (revocation bitmap lookup); those to a live object must not.
	void phase_revocation(void *buffer)
	{
		auto *slots = static_cast<void *volatile *>(buffer);
		void *live  = malloc(64);
		void *dead  = malloc(64);
		if ((live == nullptr) || (dead == nullptr))
		{
			Debug::log("FAIL phase 6: probe allocation failed");
			simulation_exit(6);
		}
		ptraddr_t deadAddress = __builtin_cheri_address_get(dead);

		for (size_t pos = 2; pos < WaySlots; pos += CapStride)
		{
			for (size_t alias = 0; alias < Aliases; alias++)
			{
				size_t s = cap_slot(pos, alias);
				size_t n = s / CapStride;
				slots[s] = make_probe((n & 1) != 0 ? dead : live, n);
			}
		}

		free(dead);

		for (size_t pos = 2; pos < WaySlots; pos += CapStride)
		{
			for (size_t alias = Aliases; alias-- > 0;)
			{
				size_t s = cap_slot(pos, alias);
				size_t n = s / CapStride;
				if ((n & 1) != 0)
				{
					check_cleared("revoked", s, deadAddress + (n % 8) * 8, slots[s]);
				}
				else
				{
					check_cap("live", s, make_probe(live, n), slots[s]);
				}
			}
		}
	}

	constexpr uint32_t icache_step(uint32_t x, uint32_t seed, uint32_t n)
	{
		x ^= seed * 0x9e3779b1u + n * 0x85ebca6bu;
		x *= 0x01000193u;
		return x ^ (x >> (9 + n % 7));
	}

#define ICACHE_STEP(n) x = icache_step(x, Seed, (n));
#define ICACHE_STEP4(n)                                                        \
	ICACHE_STEP(n) ICACHE_STEP(n + 1) ICACHE_STEP(n + 2) ICACHE_STEP(n + 3)
#define ICACHE_STEP16(n)                                                       \
	ICACHE_STEP4(n) ICACHE_STEP4(n + 4) ICACHE_STEP4(n + 8) ICACHE_STEP4(n + 12)

	constexpr uint32_t IcacheSteps = 64;
	// One store per 16 steps, each into another alias of the same cache set.
	constexpr size_t SinkStores = IcacheSteps / 16;
	static_assert(SinkStores <= Aliases, "each sink store needs its own alias");

	// Fully unrolled straight-line code, about 1.2 KiB per instance.
	// Distinct constants keep the linker from folding instances together.
	// Each store is a conflicting D-cache miss that is still waiting for its
	// write-back and refill while the following code runs into cold I-cache
	// lines, so both caches compete for the HyperRAM arbiter.
	template<uint32_t Seed>
	__attribute__((noinline)) uint32_t icache_block(uint32_t x, volatile uint32_t *sink)
	{
		ICACHE_STEP16(0)
		sink[0] = x;
		ICACHE_STEP16(16)
		sink[WayWords] = x;
		ICACHE_STEP16(32)
		sink[2 * WayWords] = x;
		ICACHE_STEP16(48)
		sink[3 * WayWords] = x;
		return x;
	}

#undef ICACHE_STEP16
#undef ICACHE_STEP4
#undef ICACHE_STEP

	// Rolled equivalent of icache_block(); records the values it must store.
	__attribute__((noinline)) uint32_t
	icache_reference(uint32_t seed, uint32_t x, uint32_t (&stored)[SinkStores])
	{
#pragma clang loop unroll(disable)
		for (uint32_t n = 0; n < IcacheSteps; n++)
		{
			x = icache_step(x, seed, n);
			if (n % 16 == 15)
			{
				stored[n / 16] = x;
			}
		}
		return x;
	}

	using IcacheBlock = uint32_t (*)(uint32_t, volatile uint32_t *);

	// Fourteen blocks (~16.5 KiB) are about twice the 8 KiB I-cache, so every
	// set cycles through more lines than ways. More blocks would push the
	// loader's ephemeral code and the library export tables past the board's
	// 64 KiB instruction memory into the heap; the linker does not catch that.
	IcacheBlock const IcacheBlocks[] = {
	  icache_block<1>,  icache_block<2>,  icache_block<3>,  icache_block<4>,
	  icache_block<5>,  icache_block<6>,  icache_block<7>,  icache_block<8>,
	  icache_block<9>,  icache_block<10>, icache_block<11>, icache_block<12>,
	  icache_block<13>, icache_block<14>};
	constexpr size_t NumIcacheBlocks =
	  sizeof(IcacheBlocks) / sizeof(IcacheBlocks[0]);

	// Runs one block with its sink stores in the cache set selected by `salt`
	// and checks both its result and the stored values.
	void run_block(volatile uint32_t *words, size_t block, uint32_t x, uint32_t salt)
	{
		size_t line = ((block * 13 + salt * 5) % (WayWords / WordsPerLine)) * WordsPerLine;
		volatile uint32_t *sink = words + line + salt % WordsPerLine;
		uint32_t           stored[SinkStores];

		uint32_t got = IcacheBlocks[block](x, sink);
		check("icache", block, icache_reference(block + 1, x, stored), got);
		for (size_t k = 0; k < SinkStores; k++)
		{
			check("icache-sink", block, stored[k], sink[k * WayWords]);
		}
	}

	// Phase 7: cycle through more code than the I-cache holds, in sequential,
	// strided and ping-pong orders, with conflicting stores inside each block.
	void phase_icache(volatile uint32_t *words)
	{
		volatile uint32_t input = 0x1234abcd;

		for (uint32_t round = 0; round < 3; round++)
		{
			for (size_t b = 0; b < NumIcacheBlocks; b++)
			{
				run_block(words, b, input + round, round);
			}
		}
		for (uint32_t round = 0; round < 2; round++)
		{
			for (size_t k = 0; k < NumIcacheBlocks; k++)
			{
				// 5 is coprime to the block count, so every block is visited.
				run_block(words, (k * 5) % NumIcacheBlocks, input ^ (round << 8), k + 3);
			}
		}
		for (size_t b = 0; b < NumIcacheBlocks / 2; b++)
		{
			for (uint32_t rep = 0; rep < 4; rep++)
			{
				run_block(words, b, input + rep, rep);
				run_block(words, b + NumIcacheBlocks / 2, input - rep, rep + 1);
			}
		}
	}

	// Phase 8: dirty D-cache conflicts right before each I-cache-missing call,
	// so both caches compete for the shared HyperRAM arbiter.
	void phase_icache_dcache(volatile uint32_t *words)
	{
		constexpr uint32_t Round = 9;
		volatile uint32_t  input = 0x5eed1234;

		for (uint32_t rep = 0; rep < 2; rep++)
		{
			for (size_t b = 0; b < NumIcacheBlocks; b++)
			{
				size_t line =
				  ((b * 7 + rep * 3) % (WayWords / WordsPerLine)) * WordsPerLine;
				for (size_t alias = 0; alias < Aliases; alias++)
				{
					size_t i = alias * WayWords + line;
					words[i] = pattern(i, Round + rep);
				}
				// For these b and rep the block's sink set never equals `line`.
				run_block(words, b, input + b + rep, b + rep + 7);
				for (size_t alias = 0; alias < Aliases; alias++)
				{
					size_t i = alias * WayWords + line;
					check("icache-dcache", i, pattern(i, Round + rep), words[i]);
				}
			}
		}
	}

	// Reads every alias of the cache set holding `target`, evicting that line.
	void evict_line_of(volatile uint32_t *words, ptraddr_t target)
	{
		ptraddr_t base = __builtin_cheri_address_get(const_cast<uint32_t *>(words));
		// Unsigned wrap-around keeps the residue correct for target < base.
		size_t offset = ((target - base) % WayBytes) / sizeof(uint32_t);
		for (size_t alias = 0; alias < Aliases; alias++)
		{
			(void)words[alias * WayWords + offset];
		}
	}

	// Phase 9: capabilities and words spilled to the stack are evicted while
	// deeper frames run and must come back unchanged.
	__attribute__((noinline)) uint32_t
	stack_recurse(volatile uint32_t *words, void *buffer, uint32_t depth)
	{
		void *volatile    caps[2];
		volatile uint32_t values[2];

		for (uint32_t k = 0; k < 2; k++)
		{
			caps[k]   = make_cap(buffer, depth * 8 + k * CapStride);
			values[k] = pattern(depth, k);
		}
		for (uint32_t k = 0; k < 2; k++)
		{
			evict_line_of(words,
			              __builtin_cheri_address_get(const_cast<void **>(&caps[k])));
			evict_line_of(words,
			              __builtin_cheri_address_get(const_cast<uint32_t *>(&values[k])));
		}

		uint32_t below = (depth == 0) ? 0 : stack_recurse(words, buffer, depth - 1);

		for (uint32_t k = 0; k < 2; k++)
		{
			evict_line_of(words,
			              __builtin_cheri_address_get(const_cast<void **>(&caps[k])));
			check_cap("stack-cap", depth, make_cap(buffer, depth * 8 + k * CapStride), caps[k]);
			check("stack-word", depth, pattern(depth, k), values[k]);
		}
		return below + 1;
	}

	void phase_stack(volatile uint32_t *words, void *buffer)
	{
		constexpr uint32_t Depth = 10;
		check("stack-depth", Depth, Depth + 1, stack_recurse(words, buffer, Depth));
	}
} // namespace

int __cheri_compartment("cache_stress") cache_stress()
{
	Debug::log("start: {} byte buffer, {} aliases per cache set, {} I-cache blocks",
	           BufferBytes,
	           Aliases,
	           NumIcacheBlocks);

	void *buffer = malloc(BufferBytes);
	if (buffer == nullptr)
	{
		Debug::log("FAIL: buffer allocation failed");
		simulation_exit(10);
	}
	auto *words = static_cast<volatile uint32_t *>(buffer);

	phase_sequential(words);
	finish_phase(1, "sequential");
	phase_conflict(words);
	finish_phase(2, "conflict");
	phase_partial(words);
	finish_phase(3, "partial stores");
	phase_mixed(words);
	finish_phase(4, "mixed widths");
	phase_capabilities(buffer);
	finish_phase(5, "capabilities");
	phase_revocation(buffer);
	finish_phase(6, "revocation");
	phase_icache(words);
	finish_phase(7, "icache");
	phase_icache_dcache(words);
	finish_phase(8, "icache+dcache");
	phase_stack(words, buffer);
	finish_phase(9, "stack");

	// Not freed: the test ends here, and quarantining 16 KiB would only add
	// revocation work to the simulation.
	Debug::log("all phases passed");
	return 0;
}
