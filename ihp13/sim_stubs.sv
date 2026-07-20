// Simulation stubs for physical-only cells.
//
// The post-layout netlist (openroad/out/croc.v) instantiates layout-only cells
// that carry no logical function and therefore ship without a Verilog model in
// the PDK. Needed only for the post-layout flow (compile_postlayout.tcl); the
// post-synthesis netlist has no pad ring.

`ifndef SIM_STUBS_SV
`define SIM_STUBS_SV

// Bond pad (70x70 um) - pure layout cell, 64 instances in croc_chip. It only
// lands metal on the pad net, so the model drives nothing:
//
//     bondpad_70x70 IO_BOND_pad_clk_i (.pad(clk_i));
//
// 'pad' is inout to match how the sg13g2_io pad cells declare their pad pin,
// so the bond pad never becomes an extra driver on the net.
module bondpad_70x70 (pad);
  inout pad;
endmodule

`endif
