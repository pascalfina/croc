/* Minimal link description for the CHERIoT bare-metal Croc image. */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  /* Program code and static data. */
  APP   (rwx) : ORIGIN = 0x10000000, LENGTH = 0xD00

  /* Reserved heap region for capability allocations. */
  HEAP  (rw)  : ORIGIN = 0x10000D00, LENGTH = 0x100

  /* Stack grows down from the top of SRAM. */
  STACK (rw)  : ORIGIN = 0x10000E00, LENGTH = 0x200
}

PHDRS
{
  text PT_LOAD FLAGS(5); /* Read + Execute */
  data PT_LOAD FLAGS(6); /* Read + Write */
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
PROVIDE(__heap_end   = ORIGIN(HEAP) + LENGTH(HEAP));
PROVIDE(__stack_limit = ORIGIN(STACK));
PROVIDE(__stack_pointer$ = ORIGIN(STACK) + LENGTH(STACK));

/* Bootrom and SoC symbols used by the Croc software image. */
PROVIDE(_eoc = 0x02000100);
PROVIDE(_trap_vector_base = 0x02000200);
PROVIDE(_trap_handler_wrapper = 0x02000300);
PROVIDE(_trap_exit = 0x02000400);
PROVIDE(corestatus = 0x03000008);
