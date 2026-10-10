/* Copyright (c) 2024 ETH Zurich and University of Bologna.
 * Licensed under the Apache License, Version 2.0, see LICENSE for details.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Authors:
 * - Paul Scheffler <paulsc@iis.ee.ethz.ch>
 * - Philippe Sauter <phsauter@iis.ee.ethz.ch> 
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
	/* Program code and static data. */
	APP   (rwxail) : ORIGIN = 0x10000000, LENGTH = 0xD00

	/* Reserved heap region for capability allocations. */
	HEAP  (rw)     : ORIGIN = 0x10000D00, LENGTH = 0x100

	/* Stack grows down from the top of SRAM. */
	STACK (rw)     : ORIGIN = 0x10000E00, LENGTH = 0x200
}

PHDRS
{
	text PT_LOAD FLAGS(5); /* tag as: Read + Execute */
	data PT_LOAD FLAGS(6); /* tag as: Read + Write */
}

SECTIONS
{
    /* Drop metadata/debug sections, not needed */
	/DISCARD/ :
	{
	*(.riscv.attributes)
	*(.comment)
	}

    /* Start placing following sections at the SRAM base address */
	. = ORIGIN(APP);

    /* Interrupt vector table */
	.vectors : ALIGN(4)
	{
	*(.vectors)
	KEEP(*(.vectors))
	} > APP :text

    /* Startup entry (first instructions executed after bootrom) */
	.text._start : ALIGN(4)
	{
	*(.text._start)
	} > APP :text

    /* Main code (text) and read-only data (rodata) */
	.text : ALIGN(4)
	{
	*(.text)
	*(.text.*)
	*(.rodata)
	*(.rodata.*)
	} > APP :text

    /* Writable data (what people colloquially call RAM) */
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

/* Global absolute symbols */

/* Place GP near the middle for efficient GP-relative access */
PROVIDE(__global_pointer$ = ADDR(.misc) + SIZEOF(.misc) / 2);

/* Heap and stack boundaries */
PROVIDE(__heap_start = ORIGIN(HEAP));
PROVIDE(__heap_end   = ORIGIN(HEAP) + LENGTH(HEAP));
PROVIDE(__stack_limit = ORIGIN(STACK));
PROVIDE(__stack_pointer$ = ORIGIN(STACK) + LENGTH(STACK));

/* Bootrom symbols (fixed addresses) */
PROVIDE(_eoc = 0x02000100);
PROVIDE(_trap_handler_wrapper = 0x02000200);
PROVIDE(_trap_exit = 0x02000300);

/* SoC register symbols */
PROVIDE(corestatus = 0x03000008);
