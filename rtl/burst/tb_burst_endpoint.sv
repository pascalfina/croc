// Testbench for burst_endpoint (Method 2, write path)
`timescale 1ns/1ps

module tb_burst_endpoint import burst_pkg::*; ();


  logic                   clk;
  logic                   rst_ni;

  burst_req_t             burst_req;   // TB → DUT   (ROLLE A treibt)
  burst_rsp_t             burst_rsp;   // DUT → TB   (TB liest: hdr_gnt, wready)

  logic                   sram_req;    // DUT → TB
  logic                   sram_we;     // DUT → TB
  logic [AddrWidth-1:0]   sram_addr;   // DUT → TB
  logic [DataWidth-1:0]   sram_wdata;  // DUT → TB
  logic [DataWidth/8-1:0] sram_be;     // DUT → TB
  logic                   sram_gnt;    // TB → DUT   (ROLLE B treibt)
  logic [DataWidth-1:0]   sram_rdata;  // TB → DUT   (ROLLE B, erst fuer Read relevant)

  // einfaches SRAM-Speichermodell  (ROLLE B schreibt hier rein)
  logic [DataWidth-1:0]   mem [0:255];

  // ──────────────────────────────────────────────────────────
  // DUT
  // ──────────────────────────────────────────────────────────
  burst_endpoint i_dut (
    .clk_i        ( clk        ),
    .rst_ni       ( rst_ni     ),
    .burst_req_i  ( burst_req  ),
    .burst_rsp_o  ( burst_rsp  ),
    .sram_req_o   ( sram_req   ),
    .sram_we_o    ( sram_we    ),
    .sram_addr_o  ( sram_addr  ),
    .sram_wdata_o ( sram_wdata ),
    .sram_be_o    ( sram_be    ),
    .sram_gnt_i   ( sram_gnt   ),
    .sram_rdata_i ( sram_rdata )
  );


  initial clk = 1'b0;
  always #5 clk = ~clk;


  assign sram_gnt   = 1'b1;     
  assign sram_rdata = '0;       
  always_ff @(posedge clk) begin
    if (sram_req && sram_we && sram_gnt)
      mem[sram_addr >> 2] <= sram_wdata;
  end


  initial begin
    // Init + Reset
    rst_ni    = 1'b0;
    burst_req = '0;
    for (int i = 0; i < 256; i++) mem[i] = 32'hDEAD_BEEF;  // auffaelliges Muster
    repeat (3) @(posedge clk);
    rst_ni = 1'b1;
    @(posedge clk); #1;


    burst_req.hdr.start_addr = 32'h0000_0100;
    burst_req.hdr.blen       = 8'd3;
    burst_req.hdr.we         = 1'b1;
    burst_req.hdr_valid      = 1'b1;
    @(posedge clk); #1;                 
    burst_req.hdr_valid      = 1'b0;

 
    for (int k = 0; k < 4; k++) begin
      burst_req.wvalid = 1'b1;
      burst_req.wdata  = 32'hCAFE_0001 + k;
      @(posedge clk); #1;               
    end
    burst_req.wvalid = 1'b0;

    repeat (2) @(posedge clk);

   
    if (mem[32'h100>>2] !== 32'hCAFE_0001) $error("[TB] D0 falsch: %h", mem[32'h100>>2]);
    if (mem[32'h104>>2] !== 32'hCAFE_0002) $error("[TB] D1 falsch: %h", mem[32'h104>>2]);
    if (mem[32'h108>>2] !== 32'hCAFE_0003) $error("[TB] D2 falsch: %h", mem[32'h108>>2]);
    if (mem[32'h10C>>2] !== 32'hCAFE_0004) $error("[TB] D3 falsch: %h", mem[32'h10C>>2]);
    $display("[TB] Check fertig @ %0t  (keine [TB]-Errors oben = alle 4 Woerter korrekt)", $time);

    $finish;
  end


  initial begin
    $dumpfile("tb_burst_endpoint.vcd");
    $dumpvars(0, tb_burst_endpoint);
  end

endmodule
