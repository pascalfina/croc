// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "util.h"
#include "config.h"
#include "uart.h"
#include "print.h"
#include "soc_ctrl.h"

// Two 8 MiB S27KS0641 devices, combined into one 16 MiB address space.
// All accesses are aligned 32-bit transfers; the current OBI frontend rejects
// byte/halfword transfers and does not preserve CHERIoT capability tags yet.
#define HB_BASE          0x0300C000u
#define HB_REG(offset)   (*reg32(HB_BASE, (offset)))
#define HB_COMMAND       0x00Cu
#define HB_STATUS        0x010u
#define HB_DECODE_ERROR  1u
#define HB_BUSY_OR_DIRTY 6u
#define RAM_BASE         0x80000000u
#define RAM_BYTES        0x01000000u
#define ADDRESS_PROBES   80u
#define MARCH_WORDS      256u
#define RANDOM_WORDS     128u
#define RANDOM_STEPS     1024u
#define RANDOM_SEED      0x6D2B79F5u

// Keep the reference values in internal SRAM, independent of the tested RAM.
static uint32_t offsets[RANDOM_WORDS];
static uint32_t expected[RANDOM_WORDS];
static uint32_t checks;
static uint32_t writes;
static volatile uint32_t phase;

static int compare(uint32_t address, uint32_t wanted, uint32_t actual) {
    ++checks;
    if (actual == wanted) return 0;
    printf("FAIL phase=0x%x addr=0x%x expected=0x%x actual=0x%x\n", phase, address, wanted, actual);
    uart_write_flush();
    return 1;
}

static void write_word(uint32_t offset, uint32_t value) {
    *reg32(RAM_BASE, offset) = value;
    ++writes;
}

static int expect_word(uint32_t offset, uint32_t value) {
    uint32_t actual = *reg32(RAM_BASE, offset);
    return compare(RAM_BASE + offset, value, actual);
}

// Unexpected access faults must fail the simulation, rather than repeatedly
// returning from the weak startup handler to the same faulting instruction.
void croc_exception_handler(uint32_t cause) {
    uint32_t pc, address;
    asm volatile("csrr %0, mepc" : "=r"(pc));
    asm volatile("csrr %0, mtval" : "=r"(address));
    printf("FAIL phase=0x%x cause=0x%x pc=0x%x mtval=0x%x\n", phase, cause, pc, address);
    uart_write_flush();
    *reg32(SOCCTRL_BASE_ADDR, SOC_CTRL_CORESTATUS_REG_OFFSET) = 3u; // EOC, return code 1.
    fence();
    for (;;) wfi();
}

static int wait_ready(void) {
    uint32_t status = 0;
    for (uint32_t n = 0; n < 100000u; ++n) {
        status = HB_REG(HB_STATUS);
        if (status & HB_DECODE_ERROR) break;
        if ((status & HB_BUSY_OR_DIRTY) == 0) return 0;
    }
    printf("FAIL controller phase=0x%x status=0x%x\n", phase, status);
    uart_write_flush();
    return 1;
}

static int hyperbus_init(void) {
    HB_REG(HB_STATUS) = HB_DECODE_ERROR;
    if (wait_ready()) return 1;

    HB_REG(0x100) = 1u; // Combine both physical buses.
    for (uint32_t chip = 1; chip < 8; ++chip) HB_REG(0x408u + chip * 0x40u) = 0u;
    HB_REG(0x400) = RAM_BASE;
    HB_REG(0x404) = RAM_BASE + RAM_BYTES;
    HB_REG(0x408) = (1u << 16) | (24u << 8);
    fence();
    HB_REG(HB_COMMAND) = 2u; // APPLY staged configuration.
    fence();
    return wait_ready();
}

static int data_patterns(void) {
    // Adjacent words at both ends exercise both physical buses and byte lanes.
    // Write the entire group before checking it, so a later write cannot hide
    // a corrupted neighbor merely because it was checked immediately before.
    for (uint32_t p = 0; p < 68u; ++p) {
        uint32_t value;
        if (p < 32u)
            value = 1u << p;
        else if (p < 64u)
            value = ~(1u << (p - 32u));
        else if (p == 64u)
            value = 0u;
        else if (p == 65u)
            value = 0xFFFFFFFFu;
        else if (p == 66u)
            value = 0xAAAAAAAAu;
        else
            value = 0x55555555u;

        for (uint32_t i = 0; i < 8u; ++i) {
            uint32_t offset = i < 4u ? i * 4u : RAM_BYTES - (8u - i) * 4u;
            write_word(offset, value);
        }
        fence();
        for (uint32_t i = 0; i < 8u; ++i) {
            uint32_t offset = i < 4u ? i * 4u : RAM_BYTES - (8u - i) * 4u;
            if (expect_word(offset, value)) return 1;
        }
    }
    return 0;
}

static uint32_t add_probe(uint32_t count, uint32_t offset) {
    if (offset >= RAM_BYTES) return count;
    for (uint32_t i = 0; i < count; ++i)
        if (offsets[i] == offset) return count;
    // At most 78 candidates are generated below; reserve 80 entries.
    if (count < ADDRESS_PROBES) offsets[count++] = offset;
    return count;
}

static int address_aliases(void) {
    uint32_t count = add_probe(0, 0);
    // Toggle every word-address bit, including the top bit, and probe the
    // adjacent words around each boundary. This is sparse, not a full sweep.
    for (uint32_t bit = 2; bit < 24u; ++bit) {
        uint32_t offset = 1u << bit;
        count           = add_probe(count, offset - 4u);
        count           = add_probe(count, offset);
        count           = add_probe(count, offset + 4u);
    }
    for (uint32_t boundary = 0x00400000u; boundary < RAM_BYTES; boundary += 0x00400000u) {
        count = add_probe(count, boundary - 4u);
        count = add_probe(count, boundary);
        count = add_probe(count, boundary + 4u);
    }
    count = add_probe(count, RAM_BYTES - 8u);
    count = add_probe(count, RAM_BYTES - 4u);

    for (uint32_t pass = 0; pass < 2u; ++pass) {
        uint32_t salt = pass ? 0xA5A55A5Au : 0x5A5AA5A5u;
        for (uint32_t i = 0; i < count; ++i) write_word(offsets[i], offsets[i] ^ salt);
        fence();
        for (uint32_t i = 0; i < count; ++i)
            if (expect_word(offsets[i], offsets[i] ^ salt)) return 1;
        for (uint32_t i = count; i != 0; --i)
            if (expect_word(offsets[i - 1u], offsets[i - 1u] ^ salt)) return 1;
    }
    return 0;
}

static int march_window(uint32_t base) {
    // March C- on 32-bit words:
    // w0; ascending(r0,w1); ascending(r1,w0);
    // descending(r0,w1); descending(r1,w0); r0.
    for (uint32_t i = 0; i < MARCH_WORDS; ++i) write_word(base + i * 4u, 0u);
    fence();
    for (uint32_t pass = 0; pass < 4u; ++pass) {
        uint32_t before = (pass & 1u) ? 0xFFFFFFFFu : 0u;
        for (uint32_t i = 0; i < MARCH_WORDS; ++i) {
            uint32_t index  = pass < 2u ? i : MARCH_WORDS - 1u - i;
            uint32_t offset = base + index * 4u;
            if (expect_word(offset, before)) return 1;
            write_word(offset, ~before);
        }
        fence();
    }
    for (uint32_t i = 0; i < MARCH_WORDS; ++i)
        if (expect_word(base + i * 4u, 0u)) return 1;
    return 0;
}

static uint32_t random_next(uint32_t *state) {
    uint32_t value = *state;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    *state = value;
    return value;
}

static int verify_reference(void) {
    for (uint32_t i = 0; i < RANDOM_WORDS; ++i)
        if (expect_word(offsets[i], expected[i])) return 1;
    return 0;
}

static int mixed_accesses(void) {
    uint32_t state = RANDOM_SEED;
    // Generate distinct word addresses across all 16 MiB. Initialize every
    // reference entry explicitly; the legacy startup does not clear BSS.
    for (uint32_t i = 0; i < RANDOM_WORDS; ++i) {
        uint32_t offset, j;
        do {
            offset = random_next(&state) & (RAM_BYTES - 4u);
            for (j = 0; j < i; ++j)
                if (offsets[j] == offset) break;
        } while (j != i);
        offsets[i]  = offset;
        expected[i] = random_next(&state);
        write_word(offset, expected[i]);
    }
    fence();
    if (verify_reference()) return 1;

    for (uint32_t step = 0; step < RANDOM_STEPS; ++step) {
        uint32_t choice = random_next(&state);
        uint32_t index  = choice & (RANDOM_WORDS - 1u);
        if (expect_word(offsets[index], expected[index])) return 1;
        if (choice & 0x100u) {
            uint32_t value = random_next(&state);
            write_word(offsets[index], value);
            fence();
            expected[index] = value;
            if (expect_word(offsets[index], value)) return 1;
        }
        // Check untouched locations too, to catch collateral corruption.
        if ((step & 63u) == 63u && verify_reference()) return 1;
    }
    return verify_reference();
}

static uint32_t cycle_low(void) {
    uint32_t cycle;
    asm volatile("csrr %0, mcycle" : "=r"(cycle)::"memory");
    return cycle;
}

static int idle_readback(void) {
    // 0.1 ms, 1 ms, and 10 ms at the testbench CPU frequency. Unsigned
    // subtraction keeps these waits correct across a low-counter wrap.
    for (uint32_t delay = TB_FREQUENCY / 10000u; delay <= TB_FREQUENCY / 100u; delay *= 10u) {
        uint32_t start = cycle_low();
        while ((uint32_t)(cycle_low() - start) < delay) asm volatile("nop");
        if (verify_reference()) return 1;
    }
    return 0;
}

int main(void) {
    checks = 0;
    writes = 0;
    phase  = 0;
    uart_init();
    printf("HyperRAM regression: init, 16 MiB, aligned 32-bit accesses\n");
    uart_write_flush();
    if (hyperbus_init()) return 1;

    phase = 1;
    printf("HyperRAM 1/5: fixed patterns and walking bits\n");
    uart_write_flush();
    if (data_patterns() || wait_ready()) return 1;

    phase = 2;
    printf("HyperRAM 2/5: address aliases and boundary neighbors\n");
    uart_write_flush();
    if (address_aliases() || wait_ready()) return 2;

    phase = 3;
    printf("HyperRAM 3/5: March C- at start, middle boundary, and end\n");
    uart_write_flush();
    if (march_window(0u) || march_window(RAM_BYTES / 2u - MARCH_WORDS * 2u) ||
        march_window(RAM_BYTES - MARCH_WORDS * 4u) || wait_ready())
        return 3;

    phase = 4;
    printf("HyperRAM 4/5: mixed accesses, seed=0x%x\n", RANDOM_SEED);
    uart_write_flush();
    if (mixed_accesses() || wait_ready()) return 4;

    phase = 5;
    printf("HyperRAM 5/5: readback after idle intervals\n");
    uart_write_flush();
    if (idle_readback() || wait_ready()) return 5;

    printf("HyperRAM test passed: checks=0x%x writes=0x%x\n", checks, writes);
    uart_write_flush();
    return 0;
}
