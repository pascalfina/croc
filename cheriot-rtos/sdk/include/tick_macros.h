// Copyright Microsoft and CHERIoT Contributors.
// SPDX-License-Identifier: MIT

#pragma once

#ifndef CPU_TIMER_HZ
#	error "Timer frequency CPU_TIMER_HZ must be defined."
#endif

#ifndef PLATFORM_TIMER_HZ
#	define PLATFORM_TIMER_HZ CPU_TIMER_HZ
#endif

#ifndef TICK_RATE_HZ
#	error "Scheduler tick rate TICK_RATE_HZ must be defined."
#endif

#if TICK_RATE_HZ <= 0 || PLATFORM_TIMER_HZ < TICK_RATE_HZ
#	error "Timer frequency must be at least the positive scheduler tick rate."
#endif

// Round a single scheduling quantum up to a whole timer increment.
#define TIMERCYCLES_PER_TICK                                                   \
	(PLATFORM_TIMER_HZ / TICK_RATE_HZ +                                        \
	 ((PLATFORM_TIMER_HZ % TICK_RATE_HZ) != 0))
#define MS_PER_TICK (1000U / TICK_RATE_HZ)

#define MS_TO_TICKS(x) ((x) / MS_PER_TICK)
