#include "config.h"

  /*        CHERIoT bare-metal startup for C programs using stack and global data. */
# 0x02000500 CheriotTrapVectorRom
# 0x02000600 CheriotTrapHandlerRom

  .section  .vectors, "ax", @progbits
  .option   push
  .option   norvc
  .align    2

  j         _start
  .word     croc_exception_handler
  .word     croc_interrupt_handler
  .option   pop

  .globl    _start
  .section  .text._start, "ax", @progbits
_start:
  /*        Capability instructions are legal only after CHERIoT is enabled. */
  li        t0, 0x02000500
  csrw      mtvec, t0 // overwrite to jump to the right trap vector

  li        t0, 0x03000018
  li        t1, 1
  sw        t1, 0(t0)

  /*        Build a bounded capability for the C stack. */
  lui       t0, %hi(__stack_pointer$)
  addi      t0, t0, %lo(__stack_pointer$)
  cspecialr csp, mtdc
  csetaddr  csp, csp, t0

  /*        Build the capability global pointer expected by the CHERIoT ABI. */
  lui       t0, %hi(__global_pointer$)
  addi      t0, t0, %lo(__global_pointer$)
  cspecialr cgp, mtdc
  csetaddr  cgp, cgp, t0

  j         main

  .weak     croc_exception_handler
croc_exception_handler:
  csrr      a0, mcause
  csrr      a1, mtval
  cspecialr c6, mepcc
  cgetaddr  a2, c6

# c4 = Memory-Root-Capability
  cspecialr c4, mtdc

# c4 points to 0x03000000
  lui       t0, 0x03000
  csetaddr  c4, c4, t0

# Publish the trap information before reporting the fatal failure.
  sw        a0, 0x1c(x4)
  sw        a1, 0x20(x4)
  sw        a2, 0x24(x4)

# CORE_STATUS = 3 -> FAIL, return code 1
  li        t1, 3
  sw        t1, 8(x4)

1:
  wfi
  j         1b


  .weak     croc_interrupt_handler
croc_interrupt_handler:
  ct.cret
