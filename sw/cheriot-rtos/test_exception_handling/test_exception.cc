// Copyright Microsoft and CHERIoT Contributors.
// SPDX-License-Identifier: MIT

#include <compartment.h>
#include <cheri-builtins.h>
#include <debug.hh>
#include <stdint.h>

using Debug = ConditionalDebug<true, "Exception handling test">;

int __cheri_compartment("test_exception") crash_test()
{
	Debug::log("Triggering a deliberate CHERI tag violation");

	uint32_t value = 0;
	volatile uint32_t *invalid = static_cast<volatile uint32_t *>(cheri_tag_clear(&value));
	*invalid = 0xdeadbeef; //cause exception 



	return 0;
}
