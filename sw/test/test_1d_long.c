#include "util.h"
#include "idma.h"
#include "config.h"

// Few-addresses side, plain 1D transfers only - no 2D / ND path at all.
//
// Preamble is the one from test_burst_huge.c. Then ITERS transfers of 256 B,
// each issuing one address for 64 beats. test_1d_short.c does the same with
// 16 B per transfer, i.e. one address for 4 beats.
//
// Kept to 6 DMA jobs in total: test_burst_method_2.c runs 11 in sequence and
// completes, so this stays inside proven territory. The check loop between
// transfers mirrors the CPU work those working tests do between their jobs.

#define NWORDS 64
#define ITERS  4                        // 4 * 256 B = 1024 B, 4 addresses

static volatile uint32_t big_src[NWORDS] __attribute__((aligned(256)));
static volatile uint32_t big_dst[NWORDS] __attribute__((aligned(256)));

int main(void) {
    for (uint32_t i = 0; i < NWORDS; i++) { big_src[i] = 0xE0000000u | i; big_dst[i] = 0; }

    idma_memcpy((uint32_t)big_dst, (uint32_t)big_src, 4);
    fence();

    idma_memcpy((uint32_t)big_dst, (uint32_t)big_src, NWORDS * 4);
    fence();
    for (uint32_t i = 0; i < NWORDS; i++)
        CHECK_ASSERT(1, big_dst[i] == (0xE0000000u | i));

    for (uint32_t k = 0; k < ITERS; k++) {
        idma_memcpy((uint32_t)big_dst, (uint32_t)big_src, NWORDS * 4);
        fence();
        for (uint32_t i = 0; i < NWORDS; i++)
            CHECK_ASSERT(2, big_dst[i] == (0xE0000000u | i));
    }

    return 0;
}
