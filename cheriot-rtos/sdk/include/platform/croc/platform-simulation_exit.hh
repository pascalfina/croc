// Croc simulator exit hook.





#pragma once

#ifdef SIMULATION
#	include <compartment-macros.h>
#	include <platform-uart.hh>
#	include <stdint.h>
#   include <stdint.h>

// uint32_t numb_nops = 50000;

static void platform_simulation_exit(uint32_t code)
{
	// wait for uart msg before writing core status
	volatile Uart *uart = MMIO_CAPABILITY(Uart, uart);
	while ((uart->LineStatus & (1u << 6)) == 0)
	{
	}

	// for (volatile uint32_t i = 0; i < numb_nops; i++)
	// {
	// 	__asm__ volatile("nop");
	// }

	// write to core status
	MMIO_CAPABILITY(uint32_t, core_status)[0] = 1u | (code << 1);
}
#endif
