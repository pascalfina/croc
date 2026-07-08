// OBI burst-compliant DMA test.
// Verifies burst advantage when there is contention

#include "util.h"
#include "idma.h"
#include "config.h"
#include "uart.h"
#include "print.h"

#define MAX_TRANSFER_WORDS 128

static volatile uint32_t dma_src[MAX_TRANSFER_WORDS] __attribute__((section(".data_cross")));
static volatile uint32_t dma_dst[MAX_TRANSFER_WORDS] __attribute__((section(".data_bank0")));

#define CONTENTION_REG    ((volatile uint32_t *)0x0300C000)
#define CONTENTION_ENABLE 1

int main(void) {
    uint64_t t0, t1;
    uint32_t idma_cycles_no_cont, idma_cycles_cont;

    static const uint32_t transfer_sizes[] = {4, 32, 128};
    const uint32_t n_sizes                 = sizeof(transfer_sizes) / sizeof(transfer_sizes[0]);

    uart_init();
    printf("n0 words  no contention  with contention\r\n");

    for (uint32_t s = 0; s < n_sizes; s++) {
        const uint32_t transfer_words = transfer_sizes[s];

        // Initialize source buffer and clear destination buffer
        for (uint32_t i = 0; i < transfer_words; i++) {
            dma_src[i] = 0xABCDE000u | i;
            dma_dst[i] = 0;
        }

        // 1. Measure iDMA Memcpy WITHOUT contention
        t0 = get_mcycle();
        idma_memcpy((uint32_t)dma_dst, (uint32_t)dma_src, transfer_words * 4);
        t1                  = get_mcycle();
        idma_cycles_no_cont = (uint32_t)(t1 - t0);
        // Verify
        for (uint32_t i = 0; i < transfer_words; i++) {
            CHECK_ASSERT(1, dma_dst[i] == (0xABCDE000u | i));
            dma_dst[i] = 0; // Clear for next run
        }
#if defined(CONTENTION_ENABLE)
        // Enable bus contention
        *CONTENTION_REG = 1;

        // 2. Measure iDMA Memcpy WITH contention
        t0              = get_mcycle();
        idma_memcpy((uint32_t)dma_dst, (uint32_t)dma_src, transfer_words * 4);
        t1               = get_mcycle();
        // Disable bus contention
        *CONTENTION_REG  = 0;
        idma_cycles_cont = (uint32_t)(t1 - t0);
        // Verify
        for (uint32_t i = 0; i < transfer_words; i++) {
            CHECK_ASSERT(2, dma_dst[i] == (0xABCDE000u | i));
        }
#endif
        printf("%d %d %d\r\n", transfer_words, idma_cycles_no_cont, idma_cycles_cont);
    }

    uart_write_flush();
    return 0;
}
