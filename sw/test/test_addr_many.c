#include "util.h"
#include "idma.h"
#include "config.h"

// Many-addresses side of the burst comparison - DMA, not CPU.
//
//   test_burst_huge : 2d(dst, src, 256, 0, 0, 50)  -> 1 address per 256 B
//   this file       : idma_memcpy(dst, src, 4) x N -> 1 address per   4 B
//
// Every DMA call here has exactly the shape that both working tests start with
// (idma_memcpy of one word). test_burst_method_2.c shows that a sequence of
// short plain transfers completes; only repeated 256 B plain transfers hung.
//
// Compare address traffic per byte, not absolute power: this moves 1024 B,
// test_burst_huge moves 12800 B.

#define NWORDS 64
#define PASSES 1                        // 64 transfers of 4 B = 256 B

static volatile uint32_t big_src[NWORDS] __attribute__((aligned(256)));
static volatile uint32_t big_dst[NWORDS] __attribute__((aligned(256)));

int main(void) {
    for (uint32_t i = 0; i < NWORDS; i++) { big_src[i] = 0xE0000000u | i; big_dst[i] = 0; }

    // first transfer must be a single word - same as test_burst_huge.c and
    // test_burst_method_2.c, which both start that way
    idma_memcpy((uint32_t)big_dst, (uint32_t)big_src, 4);
    fence();

    // The DMA jams when jobs are launched back-to-back: idma_is_done() checks
    // done_id >= job_id, so a counter that already ran ahead lets the poll
    // return while the transfer is still in flight. test_burst_huge.c and
    // test_burst_method_2.c never hit this because they do CPU work between
    // transfers; a tight loop does. This spin gives the DMA time to retire.
    for (uint32_t p = 0; p < PASSES; p++) {
        for (uint32_t i = 0; i < NWORDS; i++) {
            idma_memcpy((uint32_t)&big_dst[i], (uint32_t)&big_src[i], 4);
            fence();
            for (volatile uint32_t d = 0; d < 64; d++) { }
        }
    }

    for (uint32_t i = 0; i < NWORDS; i++)
        CHECK_ASSERT(1, big_dst[i] == (0xE0000000u | i));

    return 0;
}
