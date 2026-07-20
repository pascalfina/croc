#include "util.h"
#include "idma.h"
#include "config.h"
#include "uart.h"
#include "print.h"

// test_burst_huge.c with REPS lowered to 8, plus two additions:
//
//  1. a 2D warm-up with reps=1 in front of the real 2D job. The plain memcpy
//     warm-up only primes the plain path; the 2D job goes through the ND
//     midend, which has its own cold-start state. That path was never primed.
//
//  2. UART markers around every transfer, so a hang names itself: the last
//     line printed is the transfer that did not retire.
//
// Once this completes, the markers can be dropped again for the measurement
// run - UART activity shows up separately in the power breakdown, but a clean
// run is better.

#define NWORDS 64
#define REPS   8

static volatile uint32_t big_src[NWORDS] __attribute__((aligned(256)));
static volatile uint32_t big_dst[NWORDS] __attribute__((aligned(256)));

int main(void) {
    uart_init();

    for (uint32_t i = 0; i < NWORDS; i++) { big_src[i] = 0xE0000000u | i; big_dst[i] = 0; }

    printf("A plain warmup 4B\n");
    uart_write_flush();
    idma_memcpy((uint32_t)big_dst, (uint32_t)big_src, 4);
    fence();

    printf("B plain 256B\n");
    uart_write_flush();
    idma_memcpy((uint32_t)big_dst, (uint32_t)big_src, NWORDS * 4);
    fence();
    for (uint32_t i = 0; i < NWORDS; i++)
        CHECK_ASSERT(1, big_dst[i] == (0xE0000000u | i));

    printf("C 2d warmup reps=1\n");
    uart_write_flush();
    idma_memcpy_2d((uint32_t)big_dst, (uint32_t)big_src, NWORDS * 4, 0, 0, 1);
    fence();

    printf("D 2d reps=8\n");
    uart_write_flush();
    idma_memcpy_2d((uint32_t)big_dst, (uint32_t)big_src, NWORDS * 4, 0, 0, REPS);
    fence();

    printf("E done\n");
    uart_write_flush();
    for (uint32_t i = 0; i < NWORDS; i++)
        CHECK_ASSERT(2, big_dst[i] == (0xE0000000u | i));

    return 0;
}
