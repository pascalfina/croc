#include "util.h"
#include "idma.h"
#include "config.h"

// Byte-for-byte test_burst_huge.c, with a single line changed: the 2D job moves
// 4 B per repetition instead of 256 B.
//
//   test_addr_long.c : 2d(dst, src, 256, 0, 0,   8)  ->   8 headers, 64 beats each
//   this file        : 2d(dst, src,   8, 0, 0, 256)  -> 256 headers,  2 beats each
//
// Length 8 is used because test_burst_method_2.c already exercises it in 2D
// mode and passes; shorter lengths are untested in this design.
//
// Both move 12800 B through the same DMA, the same buffers and the same SRAM
// word, so the only difference is how often an address header goes over the
// interconnect. Everything else is kept identical on purpose - the warm-up
// transfer and the plain 256 B memcpy in front of the 2D job are what makes
// test_burst_huge.c complete, and dropping either of them makes the run hang.

#define NWORDS 64
#define REPS   50
#define OUTER  1

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


    for (uint32_t r = 0; r < OUTER; r++) {
        idma_memcpy_2d((uint32_t)big_dst, (uint32_t)big_src,
                       8,            // 8 B per repetition -> 2 beats per header
                       0, 0,
                       REPS);
        fence();
    }
    for (uint32_t i = 0; i < NWORDS; i++)
        CHECK_ASSERT(2, big_dst[i] == (0xE0000000u | i));

    return 0;
}
