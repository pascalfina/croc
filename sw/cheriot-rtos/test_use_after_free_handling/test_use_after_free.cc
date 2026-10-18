// Copyright Microsoft and CHERIoT Contributors.
// SPDX-License-Identifier: MIT

#include <compartment.h>
#include <debug.hh>
#include <fail-simulator-on-error.h>
#include <string.h>
#include <stdio.h>

using Debug = ConditionalDebug<true, "Test use after free:">;

const char* secret = "secret";

void print_Secret(void* buffer)
{
	for (size_t i = 0; i < strlen(secret); i++)
		printf("scret = %c", *((char*)buffer + i));
}

int __cheri_compartment("test_use_after_free") use_after_free()
{
	
	char* secret_buffer = (char*)malloc(69 * sizeof(uint8_t));

	strcpy(secret_buffer, secret);

	print_Secret((void*)secret_buffer);

	Debug::log("Lets get rid of the secret");

	free((void*)secret_buffer);

	print_Secret((void*)secret_buffer);

	Debug::log("Secret buffer freed");

	return 0;
}
