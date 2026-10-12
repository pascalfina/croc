#include "config.h"

/* CHERIoT bare-metal startup for C programs using stack and global data. */

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
  /* Capability instructions are legal only after CHERIoT is enabled. */
  li      t0, 0x03000018
  li      t1, 1
  sw      t1, 0(t0)

  /* Build a bounded capability for the C stack. */
  lui     t0, %hi(__stack_pointer$)
  addi    t0, t0, %lo(__stack_pointer$)
  cspecialr csp, mtdc
  csetaddr csp, csp, t0

  /* Build the capability global pointer expected by the CHERIoT ABI. */
  lui     t0, %hi(__global_pointer$)
  addi    t0, t0, %lo(__global_pointer$)
  cspecialr cgp, mtdc
  csetaddr cgp, cgp, t0

  j       main

.weak croc_exception_handler
croc_exception_handler:
  ct.cret

.weak croc_interrupt_handler
croc_interrupt_handler:
  ct.cret
