// Contention System wrapping control register and dual bank traffic generators.

module obi_contention_system import croc_pkg::*; #(
  parameter obi_pkg::obi_cfg_t SbrObiCfg = obi_pkg::ObiDefaultConfig,
  parameter obi_pkg::obi_cfg_t MgrObiCfg = obi_pkg::ObiDefaultConfig,
  parameter type               sbr_obi_req_t = logic,
  parameter type               sbr_obi_rsp_t = logic,
  parameter type               mgr_obi_req_t = logic,
  parameter type               mgr_obi_rsp_t = logic
) (
  input  logic         clk_i,
  input  logic         rst_ni,

  // Register interface (CPU write to 0x2000_0000)
  input  sbr_obi_req_t sbr_req_i,
  output sbr_obi_rsp_t sbr_rsp_o,

  // Manager ports output to crossbar
  output mgr_obi_req_t cont_bank0_req_o,
  input  mgr_obi_rsp_t cont_bank0_rsp_i,
  output mgr_obi_req_t cont_bank1_req_o,
  input  mgr_obi_rsp_t cont_bank1_rsp_i
);

  logic contention_enabled_d, contention_enabled_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      contention_enabled_q <= 1'b0;
    end else begin
      contention_enabled_q <= contention_enabled_d;
    end
  end

  // Register access logic
  logic sbr_rvalid_d, sbr_rvalid_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sbr_rvalid_q <= 1'b0;
    end else begin
      sbr_rvalid_q <= sbr_rvalid_d;
    end
  end

  assign sbr_rsp_o.gnt        = 1'b1;
  assign sbr_rvalid_d         = sbr_req_i.req;
  assign sbr_rsp_o.rvalid     = sbr_rvalid_q;
  assign sbr_rsp_o.r.rdata    = {31'b0, contention_enabled_q};
  assign sbr_rsp_o.r.err      = 1'b0;
  assign sbr_rsp_o.r.r_optional = '0;

  always_comb begin
    contention_enabled_d = contention_enabled_q;
    if (sbr_req_i.req && sbr_req_i.a.we) begin
      contention_enabled_d = sbr_req_i.a.wdata[0];
    end
  end

  // Instances
  obi_contention_generator #(
    .TargetAddr ( 32'h1000_0000 ) // Bank 0 reads
  ) i_contention_gen_bank0 (
    .clk_i,
    .rst_ni,
    .enable_i ( contention_enabled_q ),
    .obi_req_o( cont_bank0_req_o     ),
    .obi_rsp_i( cont_bank0_rsp_i     )
  );

  obi_contention_generator #(
    .TargetAddr ( 32'h1000_0800 ) // Bank 1 reads
  ) i_contention_gen_bank1 (
    .clk_i,
    .rst_ni,
    .enable_i ( contention_enabled_q ),
    .obi_req_o( cont_bank1_req_o     ),
    .obi_rsp_i( cont_bank1_rsp_i     )
  );

endmodule
