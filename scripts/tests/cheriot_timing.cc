// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Host-only arithmetic regression test.  The wide reference calculations
// deliberately use a type that is not required on the 32-bit target.
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <stdint.h>

// Exercise libdivide's portable RISC-V path instead of its x86 inline asm.
#pragma push_macro("__x86_64__")
#undef __x86_64__
#include "../../cheriot-rtos/sdk/core/scheduler/tick-conversion.h"
#pragma pop_macro("__x86_64__")

static void check_cycles(uint64_t cycles) {
    using Wide        = unsigned __int128;
    uint64_t expected = static_cast<Wide>(cycles) * TICK_RATE_HZ / PLATFORM_TIMER_HZ;
    assert(timer_ticks_for_cycles(cycles) == expected);
}

static void check_ticks(uint32_t ticks) {
    using Wide        = unsigned __int128;
    uint64_t expected = (static_cast<Wide>(ticks) * PLATFORM_TIMER_HZ + TICK_RATE_HZ - 1) / TICK_RATE_HZ;
    uint64_t cycles   = timer_cycles_for_ticks(ticks);
    assert(cycles == expected);
    assert(timer_ticks_for_cycles(cycles) == ticks);
    if (ticks != 0) {
        assert(timer_ticks_for_cycles(cycles - 1) == ticks - 1);
    }
}

int main() {
    check_ticks(0);
    check_ticks(1);
    check_ticks(TICK_RATE_HZ);
    check_ticks(std::numeric_limits<uint32_t>::max() - 1);
    check_ticks(std::numeric_limits<uint32_t>::max());
    assert(timer_cycles_for_ticks(TICK_RATE_HZ) == PLATFORM_TIMER_HZ);
    assert(timer_cycles_for_ticks(1) == TIMERCYCLES_PER_TICK);
    check_cycles(0);
    check_cycles(PLATFORM_TIMER_HZ - 1);
    check_cycles(PLATFORM_TIMER_HZ);
    check_cycles(std::numeric_limits<uint64_t>::max());

    uint64_t sample = 1;
    for (unsigned i = 0; i < 100000; i++) {
        sample = sample * 6364136223846793005ULL + 1;
        check_cycles(sample);
        check_ticks(static_cast<uint32_t>(sample));
    }
    std::puts("CHERIoT timing arithmetic: PASS");
}
