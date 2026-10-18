// Copyright Microsoft and CHERIoT Contributors.
// SPDX-License-Identifier: MIT

#include <compartment.h>
#include <debug.hh>
#include <simulator.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unwind.h>
#include <allocator.h>

using Debug        = ConditionalDebug<true, "Test use after free:">;

const char *secret = "secret";

void print_Secret(void *buffer) {
    for (size_t i = 0; i < strlen(secret); i++) {
        printf("%c", *((char *)buffer + i));
    }
}

int __cheri_compartment("test_use_after_free") use_after_free() {

    char *secret_buffer = (char *)malloc(69 * sizeof(uint8_t));

    if (secret_buffer == nullptr) {
        Debug::log("ERROR: allocation failed");
        simulation_exit(1);
    }

    strcpy(secret_buffer, secret);

    print_Secret((void *)secret_buffer);

    //Debug::log("After print secret\n\n");
    int can_free_result = heap_can_free(MALLOC_CAPABILITY, secret_buffer);
    int free_result     = free(secret_buffer);

    Debug::log("heap_can_free={}, free={}", can_free_result, free_result);
    // Debug::log("free returned {}", free_result);

    if (free_result != 0) {
        Debug::log("ERROR: free failed");
        simulation_exit(1);
    }

    Debug::log("Secret buffer freed");

    volatile bool exception_caught = false;
    CHERIOT_DURING {
        // should fail otherwise cheriot is useless
        print_Secret((void *)secret_buffer);
    }
    CHERIOT_HANDLER {
        exception_caught = true;
        Debug::log("Expected use-after-free exception caught");
    }
    CHERIOT_END_HANDLER

    if (!exception_caught) {
        Debug::log("ERROR: use-after-free was not detected");
        simulation_exit(1);
    }

    Debug::log("Use-after-free test passed");
    return 0;
}
