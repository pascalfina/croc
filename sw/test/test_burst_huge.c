#include "util.h"
#include "idma.h"
#include "config.h"

#define SIZE   256
#define NWORDS 4
#define REPS   8
#define STRIDE NWORDS*4
#define OUTER  1

static volatile uint32_t big_src[SIZE] __attribute__((aligned(256)));
static volatile uint32_t big_dst[SIZE] __attribute__((aligned(256)));

int main(void) {
    for (uint32_t i = 0; i < NWORDS * REPS; i++) { big_src[i] = 0xE0000000u | i; big_dst[i] = 0; }

    idma_memcpy((uint32_t)big_dst, (uint32_t)big_src, 4 * 4);
    //idma_memcpy((uint32_t)big_dst, (uint32_t)big_src, NWORDS * 4);
    //for (uint32_t i = 0; i < NWORDS; i++)
    //    CHECK_ASSERT(1, big_dst[i] == (0xE0000000u | i));
  
    for (uint32_t r = 0; r < OUTER; r++) {
        idma_memcpy_2d((uint32_t)big_dst, (uint32_t)big_src,
                       NWORDS * 4,
                       STRIDE, STRIDE,
                       REPS);
    }
    for (uint32_t i = 0; i < NWORDS * REPS; i++)
        CHECK_ASSERT(2, big_dst[i] == (0xE0000000u | i));

    return 0;
}
