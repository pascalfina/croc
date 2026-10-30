## Memory map

The Croc memory map currently used by the CHERIoT integration is:

```text
0x0200_0000 - 0x0200_4000   Boot ROM
0x0204_0000 - 0x0208_0000   CLINT
0x0300_0000 - 0x0300_1000   SoC control registers
0x0300_2000 - 0x0300_3000   UART
0x0300_5000 - 0x0300_6000   GPIO
0x0300_A000 - 0x0300_B000   OBI timer
0x0300_B000 - 0x0300_C000   iDMA registers

0x1000_0000 - 0x1001_0000   SRAM bank 0: 64 KiB
0x1001_0000 - 0x1002_0000   SRAM bank 1: 64 KiB / CHERIoT heap
0x1002_0000 - 0x1002_0400   Revocation bitmap: 1 KiB
```

The two SRAM banks are the logical banks exposed by the Croc crossbar. Each
logical bank contains 16,384 32-bit words. In the IHP implementation, one
logical bank is physically assembled from four `2048 x 64` SRAM macros. Thus
the crossbar still sees two banks, while the implementation uses four physical
macro slices per logical bank (eight macro instances in total).

## CHERIoT Integration Status

### Debug module limitation

The current RISC-V debug module is **not yet CHERIoT-compatible**. Its
abstract debug commands use integer scratch registers, especially:

- `x10` / `a0`
- `x8` / `s0`
- scalar debug scratch CSRs `dscratch0` and `dscratch1`

In CHERIoT mode, `x8` and `x10` have paired capability registers `c8` and
`c10`. Writing an integer value to either register clears the tag of its
paired capability. Ibex already provides the debug capability CSRs `depcc`,
`dscratchc0` and `dscratchc1`, but the current debug-module path does not use
them to preserve capability state.

**TODO:** add a CHERIoT-aware debug path that preserves capability registers
during JTAG halt, abstract register access, single-step and resume. The
existing non-CHERIoT debug path should remain unchanged.

### Bootrom and exception handling

The bootrom contains a separate CHERIoT trap path. The normal trap wrapper
uses integer stack stores, which can invalidate or fail with a CHERIoT stack
capability. The CHERIoT path therefore avoids stack access in ROM:

1. The CHERIoT trap vector at `0x0200_0500` jumps to the ROM trampoline at
   `0x0200_0600`.
2. The trampoline uses `mtdc` to create a capability for the SRAM vector table
   and `mtcc` to create an executable capability for the SRAM handler.
3. It enters the SRAM handler with `cjalr`.
4. `crt0_cheriot_stack.S` reads `mcause`, `mtval` and `mepcc`, writes them to
   SoC-control registers, reports failure through `CORE_STATUS`, and waits in
   `wfi`.

The bootrom contains two trap-vector regions because Ibex uses different trap
addressing rules depending on the CHERIoT state. With CHERIoT disabled, Ibex
normalizes `mtvec` to vectored mode (`MODE = 01`), so interrupts use
`BASE + 4 * cause`. The table at `0x0200_0200` therefore provides 32 entries
that forward all supported causes to the common integer handler. With CHERIoT
enabled, Ibex uses the aligned trap base directly for both exceptions and
interrupts. The CHERIoT startup sets that base to `0x0200_0500`, where one
entry forwards to the capability-safe trampoline at `0x0200_0600`.

The interrupt handler is currently only a minimal `ct.cret` return path. Its
CHERIoT compatibility has not been investigated yet, so interrupt entry,
context handling and return may still require a dedicated CHERIoT-aware
implementation.

**Low-priority TODO:** verify interrupt handling with CHERIoT enabled and
implement a capability-safe interrupt context save/restore path if required.

The Ibex integration also needs the trap vector table at `0x0200_0200`.
Ibex initializes `mtvec` with vectored-mode semantics when CHERIoT is
disabled and requires a 256-byte-aligned base, so the bootrom provides one
entry per trap cause. This separate vector-table adjustment was not needed
for the original CVE2 integration, whose direct trap-entry behavior matched
the old bootrom flow.

### Branch control during memory stalls

HyperRAM/tag-SRAM bring-up exposed a pre-existing Ibex branch-control bug in
`ibex/rtl/ibex_id_stage.sv`. Croc uses `WritebackStage = 1` and
`BranchTargetALU = 0`: a taken conditional branch first compares its operands,
then reuses the main arithmetic unit to calculate the destination address.
If a previous memory operation is still awaiting its response, the next
instruction can be present in decode while `instr_executing = 0` prevents
its execution. The ID state machine (`id_fsm_q`) correctly waits, but the
old code updated `branch_set_raw_q` unconditionally. The branch request
could therefore reach instruction fetch before the target-calculation phase.

In the failing trace, `csc` stored a 64-bit capability through two 32-bit OBI
transfers. While the second response was pending, the following instruction
at `0x800003b6` was `bne a0, a1, -26`, with operands 1 and 15. The premature
branch used the comparison's subtraction result, `1 - 15 = -14`
(`0xfffffff2`), instead of the intended destination `0x8000039c`. Fetching
from that invalid address raised an instruction access fault (`mcause = 1`).
The source capability's tag was valid; this failure was not a detected tag
loss or a CHERIoT bounds violation.

The fix updates `branch_set_raw_q` only when `instr_executing` is asserted,
matching the enable condition of `id_fsm_q`. The registered branch request
and the comparison/target-calculation phases consequently advance together.

This bug is not exclusive to CHERIoT. Capability stores make the relevant
overlap possible through their two transfers, and HyperRAM plus serialized
tag handling adds response latency. The previous SRAM path returned each
accepted access after one cycle, making it possible for a memory operation
to finish before the next branch reached decode. Instruction order, fetch
timing and intervening register dependencies also affect whether the bug is
exposed. Earlier passing tests therefore do not establish correctness for
longer memory stalls; without their traces, the exact reason each earlier
test avoided the failing overlap remains unverified.

The standalone decode-stage regression reproduces the failure in the old
code and passes all 40 scenarios with the fix. It covers taken and non-taken
branches, delayed load/store completion, consecutive branches, and both
legacy and CHERIoT modes with fixed-time execution enabled and disabled.
Run it from the repository root in the Verilator tool environment:

```sh
./scripts/tests/run_ibex_branch_stall.sh
```

The regression drives pending-memory conditions at the decode-stage interface;
it is not a complete capability-store or HyperRAM simulation. The full
HyperRAM/tag-SRAM test must also be rerun with a rebuilt RTL simulator.

### Tags and revocation bitmap

`tag_memory.sv` stores one tag bit for every 32-bit SRAM word. The tag memory
was extended together with the SRAM: each logical bank now has 16,384 tag
bits, for 2 KiB of tag state per bank and 4 KiB in total. Tags are currently
implemented as flip-flops, reset to zero, updated on data writes, and returned
with one-cycle read latency.

`revc_bitmap_memory.sv` stores the heap revocation metadata outside the SRAM
banks. The current configuration contains 256 32-bit words, equal to 8,192
revocation bits or 1 KiB, at `0x1002_0000 - 0x1002_0400`. This gives one
revocation bit per 8 bytes of the 64 KiB heap. The bitmap is implemented as a
flip-flop array and is accessed both through the normal OBI window and the
TRVK read path.

```text
addresses increase downward

0x1000_0000  +------------------------------------------+
              | SRAM bank 0 / RTOS image                 |
              | 64 KiB = 16384 x 32-bit words           |
              |                                          |
              | linker-managed sections:                 |
              |   loader and persistent code            |
              |   scheduler and compartment code        |
              |   read-only and static data              |
              |   trusted and thread stack sections     |
              |                                          |
              | exact internal offsets vary by image     |
0x1001_0000  +==========================================+
              | SRAM bank 1 / CHERIoT heap              |
              | 64 KiB = 16384 x 32-bit words           |
              | dynamic heap allocations                 |
0x1002_0000  +==========================================+
              | Revocation bitmap                        |
              | 1 KiB = 256 x 32-bit words = 8192 bits |
              | metadata for the 64 KiB heap             |
0x1002_0400  +------------------------------------------+
```

The revocation bitmap is metadata for the heap; it is not a replacement for
the tag memory and it is not physically stored in the SRAM banks. Normal OBI
and TRVK accesses are not yet arbitrated if they arrive simultaneously; this
is a known limitation for future work.

Tag memory is parallel metadata and has no normal CPU address range:

```text
SRAM bank 0  -> 16384 tag bits = 2 KiB
SRAM bank 1  -> 16384 tag bits = 2 KiB
                         4 KiB total tag state
```

### CHERIoT compiler and startup

The Docker image now contains the CHERIoT LLVM toolchain. The Makefile can
build all CHERIoT programs with:

```sh
make -C sw cheriot
```

`crt0_cheriot.S` is used for handwritten assembly tests. C programs use
`crt0_cheriot_stack.S`, which creates bounded stack and global-pointer
capabilities. Compiler-generated C tests can therefore use local variables,
stack objects and pointers; this has already been exercised in RTL
simulation.

### CHERIoT-RTOS

CHERIoT-RTOS uses the Croc board description in
`cheriot-rtos/sdk/boards/croc.json`. Its loader does not use the Croc test
programs' `crt0`; instead, Croc adds a platform pre-loader hook in
`cheriot-rtos/sdk/include/platform/croc/platform-early_boot_prestart.inc`.
This hook runs before the RTOS loader, installs the CHERIoT trap base at
`0x0200_0500`, and enables CHERIoT through the SoC-control register at
`0x0300_0018`. The RTOS loader therefore starts with CHERIoT enabled and can
retain the root capabilities required by the system.

The Croc UART was initially incompatible with the generic CHERIoT-RTOS UART
initialisation. Its baud-rate calculation did not match Croc's UART baud
generator, so the RTOS could remain blocked while waiting for UART progress.
The Croc platform UART now programs the fixed divisor for the 20 MHz Croc
clock and 125,000 baud, and polls the transmitter-empty status before writing.

### Trusted stack and nested compartment calls

CHERIoT-RTOS uses two different stacks for a thread:

- The normal stack contains ordinary local variables, return data and the
  application stack frames.
- The trusted stack is used by the compartment switcher for protected register
  state while crossing a compartment boundary. Application code does not use
  it as a normal C/C++ stack.

Every active compartment switch consumes one trusted-stack frame. A call chain
such as

```text
test compartment -> allocator -> software revoker
```

can therefore require several frames at the same time. The required size is
not determined by the size of the normal stack and is currently configured in
each RTOS program's `xmake.lua` through `trusted_stack_frames`. If the value is
too small, the switcher can return `ENOTENOUGHTRUSTEDSTACK` (`-141`) before the
callee runs. This can otherwise look like an unrelated failure in the
allocator or revocation code.

For the current programs, trusted-stack sizing must therefore be reviewed
when adding a compartment call, allocator operation, revoker operation or
another nested callback. The repository contains a diagnostic tool at
`scripts/analyze_trusted_stack.py`. It reads the JSON compartment report
generated by the CHERIoT linker, builds a graph of compartment-export
dependencies and reports the longest statically visible call path. For
example:

```bash
python3 scripts/analyze_trusted_stack.py \\
  sw/build/cheriot-rtos/test_use_after_free_handling/build/cheriot/cheriot/release/test_use_after_free_handling.json \\
  --xmake sw/cheriot-rtos/test_use_after_free_handling/xmake.lua \\
  --reserve 1
```

The report's `threads` entry identifies the starting compartment. The tool
adds the requested reserve to the estimated depth and compares the result
with `trusted_stack_frames` from the supplied `xmake.lua`. `--check` makes a
configured value below the recommendation fail the command, even if the
report also contains a cycle. The tool reports dependency cycles separately;
use `--strict` if cycles should additionally fail the check.

This is deliberately only a diagnostic aid, not a proof of safety. The
linker report describes possible imports, not the exact runtime call order.
Dynamic callbacks, error paths and configuration-dependent calls can require
additional frames, so the reserve and a manual review remain necessary.
