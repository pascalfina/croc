// Copyright Microsoft and CHERIoT Contributors.
// SPDX-License-Identifier: MIT

#pragma once

#include <libdivide/libdivide.h>
#include <stdint.h>
#include <tick_macros.h>

namespace
{
	static_assert(PLATFORM_TIMER_HZ <= UINT32_MAX,
	              "Timer frequency must fit in 32 bits");

	/** Convert a complete timeout at once, rounding up to avoid early expiry.
	 */
	inline uint64_t timer_cycles_for_ticks(uint32_t ticks)
	{
		if constexpr ((PLATFORM_TIMER_HZ % TICK_RATE_HZ) == 0)
		{
			return static_cast<uint64_t>(ticks) * TIMERCYCLES_PER_TICK;
		}
		else
		{
			constexpr libdivide::divider<uint64_t> TickRateDivisor(
			  TICK_RATE_HZ);
			uint64_t cycles = static_cast<uint64_t>(ticks) * PLATFORM_TIMER_HZ;
			return (cycles + TICK_RATE_HZ - 1) / TickRateDivisor;
		}
	}

	/** Count elapsed ticks without multiplying the full 64-bit timestamp. */
	inline uint64_t timer_ticks_for_cycles(uint64_t cycles)
	{
		if constexpr ((PLATFORM_TIMER_HZ % TICK_RATE_HZ) == 0)
		{
			constexpr libdivide::divider<uint64_t> TickDivisor(
			  TIMERCYCLES_PER_TICK);
			return cycles / TickDivisor;
		}
		else
		{
			constexpr libdivide::divider<uint64_t> TimerDivisor(
			  PLATFORM_TIMER_HZ);
			uint64_t seconds   = cycles / TimerDivisor;
			uint64_t remainder = cycles - seconds * PLATFORM_TIMER_HZ;
			return seconds * TICK_RATE_HZ +
			       (remainder * TICK_RATE_HZ) / TimerDivisor;
		}
	}
} // namespace
