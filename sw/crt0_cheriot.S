#include "config.h"

/* Minimal CHERIoT bare-metal startup for the Croc SRAM image. */

.section .vectors, "ax", @progbits
  .option push
  .option norvc
  .align  2

  j       _start
  .word   croc_exception_handler
  .word   croc_interrupt_handler
  .option pop

.globl _start
.section .text._start, "ax", @progbits
_start:
  /* Each bare-metal test enables CHERIoT before its first capability instruction. */
  j       main

/* The immutable bootrom still dispatches traps through integer addresses. */
.weak croc_exception_handler
croc_exception_handler:
  ct.cret

.weak croc_interrupt_handler
croc_interrupt_handler:
  ct.cret
