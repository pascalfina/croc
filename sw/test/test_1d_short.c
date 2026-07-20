#include "util.h"
#include "idma.h"
#include "config.h"

// Many-addresses side, plain 1D transfers only - same structure as
// test_1d_long.c but 16 B per transfer instead of 256 B.
//
//   test_1d_long.c  : 4 x memcpy(256 B) -> 4 addresses, 1024 B -> 1 per 256 B
//   this file       : 8 x memcpy( 16 B) -> 8 addresses,  128 B -> 1 per  16 B
//
// 16 B is proven: test_burst_method_2.c copies that length in test_length_sweep
// and passes. The full 256 B copy in the preamble fills big_dst, so the check
// loop stays valid even though each transfer only touches the first 16 B.

#define NWORDS 64
#define ITERS  8                        // 8 * 16 B = 128 B, 8 addresses

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
        idma_memcpy((uint32_t)big_dst, (uint32_t)big_src, 16);
        fence();
        for (uint32_t i = 0; i < NWORDS; i++)
            CHECK_ASSERT(2, big_dst[i] == (0xE0000000u | i));
    }

    return 0;
}
