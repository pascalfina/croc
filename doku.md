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

The Ibex integration also needs the trap vector table at `0x0200_0200`.
Ibex initializes `mtvec` with vectored-mode semantics when CHERIoT is
disabled and requires a 256-byte-aligned base, so the bootrom provides one
entry per trap cause. This separate vector-table adjustment was not needed
for the original CVE2 integration, whose direct trap-entry behavior matched
the old bootrom flow.

### Tags and revocation bitmap

`tag_memory.sv` stores one tag bit for every 32-bit SRAM word. Each SRAM bank
has 512 tag bits. Tags reset to zero, are updated on data writes, and are
returned with one-cycle read latency.

`revc_bitmap_memory.sv` currently provides:

- normal OBI reads and writes to the bitmap,
- byte-enable handling for bitmap writes,
- a separate one-cycle TRVK bitmap-read path,
- reset to a non-revoked bitmap state,
- address bounds checking for both access paths.

The current Croc configuration exposes two 32-bit bitmap words at
`0x1000_1000`. Simultaneous normal OBI and TRVK accesses are not yet handled
by an arbiter; the module currently selects one access mode. This is a known
limitation but is not required for the current single-request tests.

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
