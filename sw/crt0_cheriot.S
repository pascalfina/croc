#include "config.h"

  /*        Minimal CHERIoT bare-metal startup for the Croc SRAM image. */

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
  /*        Configure the CHERIoT trap vector before enabling CHERIoT in main. */
  li        t0, 0x02000500
  csrw      mtvec, t0
  /*        Each bare-metal test enables CHERIoT before its first capability instruction. */
  j         main

  /*        Fatal CHERIoT exception handler. */
  .weak     croc_exception_handler
croc_exception_handler:
  csrr      a0, mcause
  csrr      a1, mtval
  cspecialr c6, mepcc
  cgetaddr  a2, c6

  /*        Build a capability for the SoC-control registers. */
  cspecialr c4, mtdc
  lui       t0, 0x03000
  csetaddr  c4, c4, t0

  /*        Publish mcause, mtval and mepc before reporting failure. */
  sw        a0, 0x1c(x4)
  sw        a1, 0x20(x4)
  sw        a2, 0x24(x4)

  /*        CORE_STATUS = 3 -> FAIL (return code 1). */
  li        t1, 3
  sw        t1, 8(x4)

1:
  wfi
  j         1b

  .weak     croc_interrupt_handler
croc_interrupt_handler:
  ct.cret
