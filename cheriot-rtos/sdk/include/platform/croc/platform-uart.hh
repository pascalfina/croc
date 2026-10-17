#pragma once

#define CHERIOT_PLATFORM_CUSTOM_UART
#include_next <platform-uart.hh>
#undef CHERIOT_PLATFORM_CUSTOM_UART

struct CrocUart : public Uart16550<uint32_t>
{
	void init() volatile
	{
		Uart16550<uint32_t>::init(10);
	}

	// Croc's UART has a finite TX FIFO.  The generic simulation shortcut
	// assumes an infinitely fast receiver and can drop characters here.
	void blocking_write(uint8_t byte) volatile
	{
		while ((LineStatus & (1u << 5)) == 0)
		{
		}
		data = byte;
	}
};

using Uart = CrocUart;

static_assert(IsUart<Uart>);
