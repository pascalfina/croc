// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module pad_functional_pd (
  input  logic OEN,
  input  logic I,
  output wire  O,
  input  logic PEN,
  inout  wire  PAD
);

  // Output and pull-down enables are active low.
  assign PAD = OEN ? 1'bz : I;
  assign (pull0, highz1) PAD = PEN ? 1'bz : 1'b0;
  assign O = PAD;

endmodule
