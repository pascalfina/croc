/* Standalone test: code, globals, heap, stack, and probes are all in HyperRAM. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 0x00400000
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

  .text : ALIGN(4)
  {
    KEEP(*(.text._start))
    *(.text .text.*)
    /* CHERIoT addresses code and constants relative to the same PCC. */
    *(.rodata .rodata.*)
    . = ALIGN(4);
  } > RAM :text

  .data : ALIGN(4)
  {
    *(.sdata .sdata.*)
    *(.data .data.*)
    . = ALIGN(4);
  } > RAM :data

  .bss (NOLOAD) : ALIGN(4)
  {
    __bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM :data
  __image_end = .;

  .heap ORIGIN(RAM) + 0x10000 (NOLOAD) :
  {
    __heap_start = .;
    . += 0x10000;
    __heap_end = .;
  } > RAM :NONE

  .stack ORIGIN(RAM) + 0x20000 (NOLOAD) :
  {
    __stack_limit = .;
    . += 0x1000;
    __stack_pointer$ = .;
  } > RAM :NONE

  /* Matching local tag-word addresses in different SRAM banks. */
  .probe_bank0 ORIGIN(RAM) + 0x100000 (NOLOAD) :
  {
    __tag_bank0_probe = .;
    . += 256;
  } > RAM :NONE

  .probe_boundary ORIGIN(RAM) + 0x1ffff8 (NOLOAD) :
  {
    __tag_boundary_probe = .;
    . += 16;
  } > RAM :NONE

  .probe_bank1 ORIGIN(RAM) + 0x300000 (NOLOAD) :
  {
    __tag_bank1_probe = .;
    . += 256;
  } > RAM :NONE

  .probe_last ORIGIN(RAM) + LENGTH(RAM) - 8 (NOLOAD) :
  {
    __tag_last_probe = .;
    . += 8;
  } > RAM :NONE
}

PROVIDE(__global_pointer$ = ADDR(.data) + SIZEOF(.data) / 2);

ASSERT(_start == ORIGIN(RAM), "Entry must match the HyperRAM boot address")
ASSERT(__image_end <= __heap_start, "Program image overlaps the test heap")
ASSERT((SIZEOF(.text) % 4) == 0, "Text must support word-only HEX loading")
ASSERT((SIZEOF(.data) % 4) == 0, "Data must support word-only HEX loading")
