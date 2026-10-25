// Copyright Microsoft and CHERIoT Contributors.
// SPDX-License-Identifier: MIT

#pragma once

#include <cdefs.h>

/// Read the least significant word of the cycle counter.
__always_inline static int rdcycle()
{
	int cycles;
	#if defined(CROC)
	// Croc's Ibex configuration implements the unprivileged `cycle` CSR.
	// This is safe for CHERIoT compartments without AccessSystemRegisters.
	__asm__ volatile("rdcycle %0" : "=r"(cycles));
	#else
	// CHERIoT-Ibex does not yet implement the "cycle" CSR, so read mcycle.
	__asm__ volatile("csrr %0, mcycle" : "=r"(cycles));
	#endif
	return cycles;
}
