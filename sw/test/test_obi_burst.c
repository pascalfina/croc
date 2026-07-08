// OBI burst-compliant DMA test.
// Verifies iDMA memcpy across 1/4/16 word transfers with canary checks.

#include "util.h"
#include "idma.h"
#include "config.h"
#include "uart.h"
#include "print.h"

static volatile uint32_t dma_src[16] __attribute__((section(".data_bank0")));
static volatile uint32_t dma_dst[16] __attribute__((section(".data_bank0")));

int main(void) {
    uint64_t t0, t1;
    uart_init();
    // Length sweep: 1 word, 4 words, 16 words
    static const uint32_t lens[3] = {1, 4, 16};
    
    printf("test_obi_burst: start\n");

    for (int k = 0; k < 3; k++) {
        uint32_t len = lens[k];

        for (uint32_t i = 0; i < len; i++)
            dma_src[i] = 0xB0000000u | (len << 16) | i;

        t0 = get_mcycle();
        idma_memcpy((uint32_t)dma_dst, (uint32_t)dma_src, len * 4);
        // fence();
        t1 = get_mcycle();
        printf("  len %d: %d cycles\n", (int)len, (uint32_t)(t1 - t0));

        for (uint32_t i = 0; i < len; i++)
            CHECK_ASSERT(10 + k, dma_dst[i] == (0xB0000000u | (len << 16) | i));
    }

    uart_write_flush();
    return 0;
}
