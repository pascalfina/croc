<!--
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
-->

# HyperRAM Model Compatibility

`s27ks0641-verilator.patch` adapts the Infineon S27KS0641 model V1.9 for
Verilator 5.042. The model uses `disable` to cancel pending read-output and
self-refresh processes. Verilator supports disabling fork branches, but not
arbitrary named blocks in another process.

The patch wraps each of the seven affected named blocks in a single-branch
`fork`/`join`. The existing `disable` statements, delayed assignments, memory
logic, and protocol handling are retained. Removing the cancellation statements
would allow delayed output updates after chip deselection.

The internal differential-clock state starts at zero instead of `Z`. Otherwise,
Verilator 5.042 can split its procedural assignments into separate persistent
tristate drivers: after the first rising edge, the modeled clock stays high and
command decoding stops.

The DQ and RWDS output states use an explicit `{drive_enable, data}` encoding.
Their temporary and delayed copies carry the enable bit together with the data;
only the final continuous pin drivers produce `Z`. This avoids the same stale
driver problem on the read-data and read-strobe outputs while retaining the
existing output delays and cancellation. When inspecting the generated model,
`Dout_zd` and its copies are therefore nine bits wide, and `RWDSout_zd` and its
copies are two bits wide. The external pin widths are unchanged. The two timing
check helper signals test these enable bits instead of comparing against `Z`.

The generated model also uses the actively driven `RESETNeg` directly instead
of testing whether the input is floating. Croc always drives this signal through
an enabled output pad. The Verilator variant therefore requires a driven reset;
it does not emulate the vendor model's pull-up fallback for an open reset pin.

`run_verilator.sh` automatically runs `scripts/prepare_hyperram_model.sh` before
generating either simulation file list. It creates an ignored local copy named
`s27ks0641_verilator.v`; the downloaded `s27ks0641.v` is never modified. Other
simulators still use the original model. Install the separately licensed vendor
model first; neither model copy is distributed by this repository.

For a direct Bender invocation, first run `bash scripts/prepare_hyperram_model.sh`
from the Croc repository root.

These adaptations address process cancellation and internal tristate state.
They do not add support for the model's `specify` timing checks or certify its
complete Verilator behavior. The clock and output-state changes were checked
statically; a fresh Verilator build and a write/read simulation are still needed
to validate them.
