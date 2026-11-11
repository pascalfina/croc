module configurable_delay #(
  parameter int unsigned NUM_STEPS = 32,
  localparam int unsigned DELAY_SEL_WIDTH = $clog2(NUM_STEPS)
) (
  input  logic                       clk_i,
  input  logic [DELAY_SEL_WIDTH-1:0] delay_i,
  output logic                       clk_o
);

  if (NUM_STEPS < 2 || (NUM_STEPS & (NUM_STEPS - 1)) != 0) begin : gen_invalid_steps
    $error("configurable_delay: NUM_STEPS must be a power of two of at least 2.");
  end


  logic [2*NUM_STEPS-2:0] node;

  assign node[NUM_STEPS-1] = clk_i;

  for (genvar k = 1; k < NUM_STEPS; k++) begin : gen_delay_chain
    (* keep *)(* dont_touch = "true" *)
    sg13g2_dlygate4sd1_1 i_delay (
      .A ( node[NUM_STEPS-2+k] ),
      .X ( node[NUM_STEPS-1+k] )
    );
  end

  for (genvar n = 0; n < NUM_STEPS - 1; n++) begin : gen_mux_tree
    localparam int unsigned Depth = $clog2(n + 2) - 1;
    tc_clk_mux2 i_mux (
      .clk0_i    ( node[2*n+1]                       ),
      .clk1_i    ( node[2*n+2]                       ),
      .clk_sel_i ( delay_i[DELAY_SEL_WIDTH-1-Depth]  ),
      .clk_o     ( node[n]                           )
    );
  end

  assign clk_o = node[0];

endmodule
