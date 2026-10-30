#include "config.h"

    .option norvc
    .option norelax
    .section .text._start, "ax", @progbits
    .globl _start
    .type _start, @function
_start:
    csrw     mie, zero
    csrci    mstatus, 8
    lui      t0, %hi(tag_sram_trap)
    addi     t0, t0, %lo(tag_sram_trap)
    csrw     mtvec, t0

    li       t0, SOCCTRL_BASE_ADDR + 0x18
    li       t1, 1
    sw       t1, 0(t0)
    cspecialr c3, mtdc

    lui      a0, %hi(__stack_limit)
    addi     a0, a0, %lo(__stack_limit)
    csetaddr c2, c3, a0
    lui      a1, %hi(__stack_pointer$)
    addi     a1, a1, %lo(__stack_pointer$)
    sub      a1, a1, a0
    csetboundsexact c2, c2, a1
    cincoffset c2, c2, a1

    lui      a0, %hi(__global_pointer$)
    addi     a0, a0, %lo(__global_pointer$)
    csetaddr c3, c3, a0

    /* Use a local trap entry instead of the old SRAM trampoline. */
    cspecialr c5, mtcc
    lui      a0, %hi(tag_sram_trap)
    addi     a0, a0, %lo(tag_sram_trap)
    csetaddr c5, c5, a0
    cspecialw mtcc, c5

    lui      a0, %hi(__bss_start)
    addi     a0, a0, %lo(__bss_start)
    csetaddr c5, c3, a0
    lui      a1, %hi(__bss_end)
    addi     a1, a1, %lo(__bss_end)
.Lzero_bss:
    bgeu     a0, a1, .Lbss_done
    sw       zero, 0(x5)
    cincoffset c5, c5, 4
    addi     a0, a0, 4
    j        .Lzero_bss
.Lbss_done:
    cjal     main

    cspecialr c4, mtdc
    li       a1, SOCCTRL_BASE_ADDR
    csetaddr c4, c4, a1
    slli     a0, a0, 1
    ori      a0, a0, 1
    sw       a0, 8(x4)
.Lhalt:
    wfi
    j        .Lhalt
    .size _start, .-_start

    .section .text, "ax", @progbits
    .balign 256
    .type tag_sram_trap, @function
tag_sram_trap:
    csrr     a0, mcause
    csrr     a1, mtval
    cspecialr c6, mepcc
    cgetaddr a2, c6
    cspecialr c3, mtdc
    li       a3, SOCCTRL_BASE_ADDR
    csetaddr c4, c3, a3
    sw       a0, 0x1c(x4)
    sw       a1, 0x20(x4)
    sw       a2, 0x24(x4)

    lui      a3, %hi(test_phase)
    addi     a3, a3, %lo(test_phase)
    csetaddr c5, c3, a3
    lw       a0, 0(x5)
    ori      a0, a0, 0x80
    slli     a0, a0, 1
    ori      a0, a0, 1
    sw       a0, 8(x4)
    j        .Lhalt
    .size tag_sram_trap, .-tag_sram_trap
