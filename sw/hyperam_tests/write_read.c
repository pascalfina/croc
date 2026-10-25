#include "util.h"
#include "config.h"
#include "uart.h"
#include "print.h"

#define HB_BASE 0x0300C000u
#define HB_REG(offset) (*reg32(HB_BASE, (offset)))

static int hyperbus_wait_ready(void)
{
    for (unsigned n = 0; n < 100000u; ++n) {
        uint32_t status = HB_REG(0x010);
        /* Bit 1: busy; Bit 2: configuration not yet applied. */
        if ((status & 6u) == 0)
            return 0;
    }
    return -1;
}

static int hyperbus_init(void)
{
    HB_REG(0x010) = 1u; /* Clear an old decode-error flag. */
    if (hyperbus_wait_ready() != 0)
        return -1;

    HB_REG(0x100) = 1u; /* Use both physical buses together. */

    for (unsigned chip = 1; chip < 8; ++chip)
        HB_REG(0x408u + chip * 0x40u) = 0u;

    HB_REG(0x400) = 0x80000000u; /* Inclusive start. */
    HB_REG(0x404) = 0x81000000u; /* Exclusive end: 16 MiB. */
    HB_REG(0x408) = (1u << 16) | (24u << 8);
    /* Enable CS0; use the lower 24 address bits within this range. */

    fence();
    HB_REG(0x00C) = 2u; /* APPLY: activate the staged configuration. */
    fence();

    return hyperbus_wait_ready();
}


int main()
{
    uart_init();

    printf("init hyper bus\n");
    uart_write_flush();
    if (hyperbus_init() != 0)
        return -1;


    volatile uint32_t *ram = (volatile uint32_t *)0x80000000u;

    printf("writ to hyper bus\n");
    uart_write_flush();
    ram[0] = 0x12345678u;
    ram[1] = 0xA5A55A5Au;
    fence();

    printf("read from hyper bus\n");
    uart_write_flush();

    uint32_t first  = ram[0];
    uint32_t second = ram[1];

    fence();

    CHECK_ASSERT(1, first == 0x12345678);
    CHECK_ASSERT(2, second == 0xA5A55A5A);

    printf("Test passed\n");
    uart_write_flush();

    return 0;

}



