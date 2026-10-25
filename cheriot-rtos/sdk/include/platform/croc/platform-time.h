// Copyright Microsoft and CHERIoT Contributors.
// SPDX-License-Identifier: MIT

#pragma once

#include <cdefs.h>
#include <compartment-macros.h>
#include <stdbool.h>
#include <stdint.h>

/* Croc's CLINT mtime is clocked by the 32.768 kHz reference clock. */
#define CROC_CLINT_MTIME_LOW_WORD 0x2ffe
#define CROC_CLINT_MTIME_HIGH_WORD 0x2fff

__if_c(static) inline uint64_t platform_monotonic_time_read()
{
	volatile uint32_t *clint = MMIO_CAPABILITY_WITH_PERMISSIONS(
	  uint32_t, clint, true, false, false, false, false);
	uint32_t mtimehBefore;
	uint32_t mtime;
	uint32_t mtimehAfter;

	/* Read the high word twice so a low-word rollover cannot produce a
	 * backwards timestamp. */
	do
	{
		mtimehBefore = clint[CROC_CLINT_MTIME_HIGH_WORD];
		mtime        = clint[CROC_CLINT_MTIME_LOW_WORD];
		mtimehAfter  = clint[CROC_CLINT_MTIME_HIGH_WORD];
	} while (mtimehBefore != mtimehAfter);

	return ((uint64_t)mtimehAfter << 32) | mtime;
}

#undef CROC_CLINT_MTIME_LOW_WORD
#undef CROC_CLINT_MTIME_HIGH_WORD
