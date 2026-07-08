// Standalone OBI contention generator module.
// Generates continuous read requests to a target address when enabled.

module obi_contention_generator import croc_pkg::*; #(
  parameter bit [31:0] TargetAddr = 32'h1000_0000
) (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         enable_i,
  output mgr_obi_req_t obi_req_o,
  input  mgr_obi_rsp_t obi_rsp_i
);
  assign obi_req_o.req          = enable_i;
  assign obi_req_o.a.addr       = TargetAddr;
  assign obi_req_o.a.we         = 1'b0; // Read request
  assign obi_req_o.a.be         = 4'hF;
  assign obi_req_o.a.wdata      = '0;
  assign obi_req_o.a.aid        = '0;
  assign obi_req_o.a.a_optional = '0;
endmodule
