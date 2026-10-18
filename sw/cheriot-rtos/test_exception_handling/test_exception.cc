// Copyright Microsoft and CHERIoT Contributors.
// SPDX-License-Identifier: MIT

#include <cheri-builtins.h>
#include <compartment.h>
#include <debug.hh>
#include <simulator.h>
#include <stdint.h>
#include <unwind.h>

using Debug = ConditionalDebug<true, "Exception handling test">;

int __cheri_compartment("test_exception") crash_test()
{
	Debug::log("Triggering a deliberate CHERI tag violation");

	uint32_t value = 0;
	volatile uint32_t *invalid =
	static_cast<volatile uint32_t *>(cheri_tag_clear(&value));
	volatile bool exception_caught = false;

	CHERIOT_DURING
	{
		*invalid = 0xdeadbeef;
	}
	CHERIOT_HANDLER
	{
		exception_caught = true;
		Debug::log("Expected CHERI exception caught");
	}
	CHERIOT_END_HANDLER

	if (!exception_caught)
	{
		Debug::log("ERROR: Expected CHERI exception did not occur");
		simulation_exit(1);
	}

	Debug::log("Exception test passed");
	return 0;
}
