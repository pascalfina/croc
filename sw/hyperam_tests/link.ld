/* Copyright 2026 ETH Zurich and University of Bologna.
 * Licensed under the Apache License, Version 2.0, see LICENSE for details.
 * SPDX-License-Identifier: Apache-2.0
 */

/* Keep the regression and its reference arrays in the first 64 KiB SRAM bank.
 * The ordinary legacy programs retain their original 4 KiB layout in link.ld.
 * No executable, stack, or reference data is placed in the RAM under test.
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    APP   (rwxail) : ORIGIN = 0x10000000, LENGTH = 0xE000
    HEAP  (rw)     : ORIGIN = 0x1000E000, LENGTH = 0x1000
    STACK (rw)     : ORIGIN = 0x1000F000, LENGTH = 0x1000
}

PHDRS
{
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}

SECTIONS
{
    /DISCARD/ :
    {
        *(.riscv.attributes)
        *(.comment)
    }

    . = ORIGIN(APP);
    .vectors : ALIGN(4)
    {
        KEEP(*(.vectors))
    } > APP :text

    .text._start : ALIGN(4)
    {
        *(.text._start)
    } > APP :text

    .text : ALIGN(4)
    {
        *(.text)
        *(.text.*)
        *(.rodata)
        *(.rodata.*)
    } > APP :text

    .misc : ALIGN(4)
    {
        *(.sdata)
        *(.sdata.*)
        *(.data)
        *(.data.*)
        *(.sbss)
        *(.sbss.*)
        *(.bss)
        *(.bss.*)
        *(COMMON)
    } > APP :data
}

PROVIDE(__global_pointer$ = ADDR(.misc) + SIZEOF(.misc) / 2);
PROVIDE(__heap_start = ORIGIN(HEAP));
PROVIDE(__heap_end = ORIGIN(HEAP) + LENGTH(HEAP));
PROVIDE(__stack_limit = ORIGIN(STACK));
PROVIDE(__stack_pointer$ = ORIGIN(STACK) + LENGTH(STACK));

PROVIDE(_eoc = 0x02000100);
PROVIDE(_trap_vector_base = 0x02000200);
PROVIDE(_trap_handler_wrapper = 0x02000300);
PROVIDE(_trap_exit = 0x02000400);
PROVIDE(corestatus = 0x03000008);
