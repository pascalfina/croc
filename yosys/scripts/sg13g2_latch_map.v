// Map Yosys' active-low level-sensitive latch to the SG13G2 latch cell.
// $_DLATCH_N_ is transparent while E is low, whereas sg13g2_dlhq_1
// is transparent while GATE is high.
module \$_DLATCH_N_ (input E, input D, output Q);
  wire gate;

  sg13g2_inv_1 gate_inverter (
    .Y (gate),
    .A (E)
  );

  sg13g2_dlhq_1 _TECHMAP_REPLACE_ (
    .Q    (Q),
    .D    (D),
    .GATE (gate)
  );
endmodule
