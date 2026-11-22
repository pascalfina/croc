// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Netlist-simulation models of the sequential EZ130 cells. Verilator lowers the
// sequential UDPs of the PDK models to blocking assignments, which race in flop
// chains (shift registers, synchronizers). The PDK copy only fixes DFFQX1 and
// DFFRQX1, but Yosys picks among equal-area cells by version (0.60: DFFRQX3,
// 0.69: DFFRQX1), so all drive strengths are covered here.
// Must be read before ez130_8t.v: Verilator keeps the first definition.
`timescale 1ns/1ps
/* verilator lint_off MODDUP */
`define EZ130_DFFQ(name) \
  module name (output logic Q, input logic D, input logic CK); \
    always_ff @(posedge CK) Q <= D; \
  endmodule

`define EZ130_DFFRQ(name) \
  module name (output logic Q, input logic D, input logic RB, input logic CK); \
    always_ff @(posedge CK or negedge RB) Q <= RB ? D : 1'b0; \
  endmodule

`define EZ130_LATQ(name, open) \
  module name (output logic Q, input logic D, input logic CK); \
    always_latch if (open) Q = D; \
  endmodule

`define EZ130_CGTS(name) \
  module name (output logic ECK, input logic E, input logic SE, input logic CK); \
    logic en; \
    always_latch if (!CK) en = E | SE; \
    assign ECK = CK & en; \
  endmodule

`EZ130_DFFQ(DFFQX1)
`EZ130_DFFQ(DFFQX1P5)
`EZ130_DFFQ(DFFQX2)
`EZ130_DFFQ(DFFQX3)
`EZ130_DFFQ(DFFQX4)
`EZ130_DFFQ(DFFQX6)

`EZ130_DFFRQ(DFFRQX1)
`EZ130_DFFRQ(DFFRQX1P5)
`EZ130_DFFRQ(DFFRQX2)
`EZ130_DFFRQ(DFFRQX3)
`EZ130_DFFRQ(DFFRQX4)
`EZ130_DFFRQ(DFFRQX6)

`EZ130_LATQ(LATQX1, CK)
`EZ130_LATQ(LATQX2, CK)
`EZ130_LATQ(LATQX3, CK)
`EZ130_LATQ(LATNQX1, !CK)
`EZ130_LATQ(LATNQX2, !CK)
`EZ130_LATQ(LATNQX3, !CK)

`EZ130_CGTS(CGTSX1)
`EZ130_CGTS(CGTSX1P5)
`EZ130_CGTS(CGTSX2)
`EZ130_CGTS(CGTSX3)

`undef EZ130_DFFQ
`undef EZ130_DFFRQ
`undef EZ130_LATQ
`undef EZ130_CGTS
/* verilator lint_on MODDUP */
