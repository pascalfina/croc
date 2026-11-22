// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Netlist-simulation model of the EZ130 delay cell. The PDK model is a plain buf
// with a zero specify delay, leaving the HyperBus delay lines of
// configurable_delay.sv at 0 ps. 78 ps per tap matches the
// configurable_delay.behav.sv model used at RTL.
// Must be read before ez130_8t.v: Verilator keeps the first definition.
`timescale 1ps/1ps
/* verilator lint_off MODDUP */
module DLY1X2 (
  output logic Y,
  input  logic A
);
  always @(A) Y <= #78ps A;
endmodule
/* verilator lint_on MODDUP */
