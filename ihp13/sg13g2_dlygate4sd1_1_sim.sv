// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Netlist-simulation model of the IHP delay gate. The PDK model is a plain buf
// whose specify delays Verilator ignores, leaving the HyperBus delay lines of
// configurable_delay.sv at 0 ps. 78 ps per tap matches the
// configurable_delay.behav.sv model used at RTL.
// Must be read before sg13g2_stdcell.v: Verilator keeps the first definition.
`timescale 1ps/1ps
/* verilator lint_off MODDUP */
module sg13g2_dlygate4sd1_1 (
  output logic X,
  input  logic A
);
  always @(A) X <= #78ps A;
endmodule
/* verilator lint_on MODDUP */
