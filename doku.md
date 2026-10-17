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
