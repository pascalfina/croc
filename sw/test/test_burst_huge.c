#include "util.h"
#include "idma.h"
#include "config.h"


#define NWORDS 64
#define REPS   2000
#define OUTER  8

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
                       NWORDS * 4,   
                       0, 0,         
                       REPS);
        fence();
    }
    for (uint32_t i = 0; i < NWORDS; i++)
        CHECK_ASSERT(2, big_dst[i] == (0xE0000000u | i));

    return 0;
}
