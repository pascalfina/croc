// Map Yosys' active-low level-sensitive latch to the EZ130 latch cell.
// $_DLATCH_N_ is transparent while E is low, and so is LATNQX1 while CK is low.
module \$_DLATCH_N_ (input E, input D, output Q);
  LATNQX1 _TECHMAP_REPLACE_ (
    .Q  (Q),
    .D  (D),
    .CK (E)
  );
endmodule
