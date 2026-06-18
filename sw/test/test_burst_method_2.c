#include "util.h"
#include "idma.h"
#include "config.h"

#define SRAM_BASE   0x10000000u
#define BANK_BIT    0x00000800u
#define bank_of(a)  ((((uint32_t)(a)) & BANK_BIT) ? 1u : 0u)
#define SENT        0x5A5A5A5Au

static volatile uint32_t dma_src[16];
static volatile uint32_t dma_dst[18];
static volatile uint32_t cpu_area[8];

static volatile uint32_t src_2d[4] = {0x2D0000A0, 0x2D0000B1, 0x2D0000C2, 0x2D0000D3};
static volatile uint32_t dst_2d[4];

static int test_length_sweep(void) {
    static const uint32_t lens[3] = {1, 4, 16};

    for (int k = 0; k < 3; k++) {
        uint32_t len = lens[k];

        for (uint32_t i = 0; i < len; i++){
            dma_src[i] = 0xB0000000u | (len << 16) | i;
        }

        dma_dst[0]  = SENT;
        dma_dst[17] = SENT;
        for (uint32_t i = 0; i < 16; i++){
            dma_dst[1 + i] = SENT;
        }

        idma_memcpy((uint32_t)&dma_dst[1], (uint32_t)dma_src, len * 4);
        fence();

        for (uint32_t i = 0; i < len; i++){
            CHECK_ASSERT(10 + k, dma_dst[1 + i] == (0xB0000000u | (len << 16) | i));
        }

        CHECK_ASSERT(20 + k, dma_dst[0] == SENT);
        CHECK_ASSERT(20 + k, dma_dst[17] == SENT);
        for (uint32_t i = len; i < 16; i++){
            CHECK_ASSERT(20 + k, dma_dst[1 + i] == SENT);
        }
    }
    return 0;
}

static int test_back_to_back(void) {
    uint32_t id[3];

    for (int j = 0; j < 3; j++) {

        for (uint32_t i = 0; i < 8; i++){
            dma_src[i] = 0xC0000000u | ((uint32_t)j << 16) | i;
        }
        for (uint32_t i = 0; i < 8; i++){
            dma_dst[1 + i] = 0;
        }
        id[j] = idma_memcpy((uint32_t)&dma_dst[1], (uint32_t)dma_src, 8 * 4);
        fence();

        for (uint32_t i = 0; i < 8; i++){
            CHECK_ASSERT(30 + j, dma_dst[1 + i] == (0xC0000000u | ((uint32_t)j << 16) | i));
        }
    }

    CHECK_ASSERT(38, id[1] > id[0]);
    CHECK_ASSERT(39, id[2] > id[1]);
    return 0;
}

static int test_bank0_read(void) {
    uint32_t b0 = SRAM_BASE + 0x40;

    CHECK_ASSERT(40, bank_of(b0) == 0);
    CHECK_ASSERT(40, bank_of(&dma_dst[1]) == 1);

    idma_memcpy((uint32_t)&dma_dst[1], b0, 8 * 4);
    idma_memcpy((uint32_t)&dma_dst[9], b0, 8 * 4);
    fence();

    for (uint32_t i = 0; i < 8; i++){
        CHECK_ASSERT(41, dma_dst[1 + i] == dma_dst[9 + i]);
    }
    return 0;
}

static int test_2d(void) {
    for (uint32_t i = 0; i < 4; i++){
        dst_2d[i] = 0;
    }

    idma_memcpy_2d((uint32_t)dst_2d, (uint32_t)src_2d, 8, 8, 8, 2);
    fence();

    for (uint32_t i = 0; i < 4; i++){
        CHECK_ASSERT(50, dst_2d[i] == src_2d[i]);
    }
    return 0;
}

static int test_contention(void) {
    const uint32_t CPU_BASE = 0x000C9000u;

    for (uint32_t i = 0; i < 16; i++){
        dma_src[i] = 0xD00D0000u | i;
    }
    dma_dst[0]  = SENT;
    dma_dst[17] = SENT;
    for (uint32_t i = 0; i < 16; i++){
        dma_dst[1 + i] = 0;
    }
    
    idma_set_nd_enable(0);
    idma_set_src_addr((uint32_t)dma_src);
    idma_set_dst_addr((uint32_t)&dma_dst[1]);
    idma_set_length(16 * 4);
    uint32_t id = idma_launch();

    for (uint32_t i = 0; i < 8; i++)
        cpu_area[i] = CPU_BASE | i;
    uint32_t acc = 0;
    for (uint32_t i = 0; i < 8; i++)
        acc += cpu_area[i];

    while (!idma_is_done(id))
        ;
    fence();

    for (uint32_t i = 0; i < 16; i++)
        CHECK_ASSERT(60, dma_dst[1 + i] == (0xD00D0000u | i));
    CHECK_ASSERT(61, dma_dst[0] == SENT && dma_dst[17] == SENT);
    for (uint32_t i = 0; i < 8; i++)
        CHECK_ASSERT(62, cpu_area[i] == (CPU_BASE | i));
    CHECK_ASSERT(63, acc == (8u * CPU_BASE + 28u));
    return 0;
}

int main(void) {
    CHECK_CALL(test_length_sweep());
    CHECK_CALL(test_back_to_back());
    CHECK_CALL(test_bank0_read());
    CHECK_CALL(test_2d());
    CHECK_CALL(test_contention());
    return 0;
}
