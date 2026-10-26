# HyperRAM Functional Tests

These are legacy C programs using `crt0.S`, without CHERIoT or the RTOS.
`write_read.c` is the short smoke test. `test_hyperram.c` adds a deterministic
regression for the current two-lane setup: two 8 MiB S27KS0641 models combined
into the 16 MiB window `[0x80000000, 0x81000000)`.

The regression checks:

- Walking ones, walking zeros, and fixed patterns in adjacent words at both ends.
- Distinct values at sparse addresses covering every word-address bit and
  neighbors of power-of-two and 4 MiB boundaries. All probe locations are
  written before verification, so address aliases cannot pass by immediate
  write/readback alone.
- Word-oriented March C- sequences over three 1 KiB windows: at the beginning,
  across the 8 MiB boundary, and at the end of the configured memory.
- 1,024 reproducible mixed accesses to 128 distinct distributed addresses,
  with expected values stored in internal SRAM. The seed is `0x6D2B79F5`.
  Periodic full checks also verify locations untouched by recent writes.
- Readback after idle intervals of approximately 0.1, 1, and 10 ms at 20 MHz.

All accesses are aligned 32-bit words. This is a functional sample of the
address space, not an exhaustive 16 MiB sweep, physical DRAM retention
qualification, or verification of analog timing. Capability tags, subword
accesses, and intentionally invalid transactions are not tested.

The larger regression has a dedicated linker script, using the first 64 KiB
of internal SRAM for code, reference values, heap reservation, and a 4 KiB
stack. The RAM under test holds none of these. Other legacy programs keep
their existing linker layout. The existing Makefile source wildcard includes
the new program in `make -C sw compile` and `make -C sw all`.

Build only the regression and its HEX/dump files from the repository root:

```bash
make -C sw bin/hyperam_tests/test_hyperram.hex bin/hyperam_tests/test_hyperram.dump
```

Run it with the previously built RTL simulator:

```bash
cd verilator
./run_verilator.sh --run ../sw/bin/hyperam_tests/test_hyperram.hex
```

Each phase prints one progress line. A mismatch reports its phase, address,
expected value, and actual value, then returns a nonzero code through the boot
ROM's EOC path. Unexpected exceptions print their cause, PC, and trap value
and set Core Status to failure. Success is reported only after all five phases
and controller-status checks have passed. Build and simulation remain manual.
