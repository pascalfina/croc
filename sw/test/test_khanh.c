#include "util.h"
#include "idma.h"
#include "config.h"
#include "uart.h"
#include "print.h"
#include "gpio.h"

#define TRANSFER_WORDS 128

static volatile uint32_t dma_src[TRANSFER_WORDS] __attribute__((section(".data_bank0")));
static volatile uint32_t dma_dst[TRANSFER_WORDS] __attribute__((section(".data_bank0")));

#define CONTENTION_REG    ((volatile uint32_t *)0x0300C000)
//#define CONTENTION_ENABLE 1  // RUN D: runtime contention enable

int main(void) {
    uint64_t t0, t1;
    uint32_t idma_cycles_no_cont, idma_cycles_cont;

    //uart_init();
    //printf("  Transfer size: %d words (%d bytes)\n", TRANSFER_WORDS, TRANSFER_WORDS * 4);

    // Initialize source buffer and clear destination buffer
    for (uint32_t i = 0; i < TRANSFER_WORDS; i++) {
        dma_src[i] = 0xABCDE000u | i;
        dma_dst[i] = 0;
    }

    gpio_set_direction(0x1, 0x1);
    gpio_enable(0x1);

    // 1. Measure iDMA Memcpy WITHOUT contention
    gpio_write(0x1);
    t0 = get_mcycle();
    idma_memcpy((uint32_t)dma_dst, (uint32_t)dma_src, TRANSFER_WORDS * 4);
    t1                  = get_mcycle();
    gpio_write(0x0);
    idma_cycles_no_cont = (uint32_t)(t1 - t0);
    // Verify
    for (uint32_t i = 0; i < TRANSFER_WORDS; i++) {
        CHECK_ASSERT(1, dma_dst[i] == (0xABCDE000u | i));
        dma_dst[i] = 0; // Clear for next run
    }
    //printf("  iDMA memcpy (no contention): %d cycles\n", idma_cycles_no_cont);
#if defined(CONTENTION_ENABLE)
    // Enable bus contention
    *CONTENTION_REG = 1;

    // 2. Measure iDMA Memcpy WITH contention
    t0              = get_mcycle();
    idma_memcpy((uint32_t)dma_dst, (uint32_t)dma_src, TRANSFER_WORDS * 4);
    t1               = get_mcycle();
    // Disable bus contention
    *CONTENTION_REG  = 0;
    idma_cycles_cont = (uint32_t)(t1 - t0);
    // Verify
    for (uint32_t i = 0; i < TRANSFER_WORDS; i++) {
        CHECK_ASSERT(2, dma_dst[i] == (0xABCDE000u | i));
    }
    printf("  iDMA memcpy (WITH contention): %d cycles\n", idma_cycles_cont);
#endif

    //uart_write_flush();
    return 0;
}