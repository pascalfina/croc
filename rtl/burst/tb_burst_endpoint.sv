// Testbench for burst_endpoint (Method 2, write + read path)
`timescale 1ns/1ps

module tb_burst_endpoint import burst_pkg::*; ();

  logic                   clk;
  logic                   rst_ni;

  burst_req_t             burst_req;   // TB → DUT   (ROLLE A treibt)
  burst_rsp_t             burst_rsp;   // DUT → TB   (TB liest)

  logic                   sram_req;    // DUT → TB
  logic                   sram_we;     // DUT → TB
  logic [AddrWidth-1:0]   sram_addr;   // DUT → TB
  logic [DataWidth-1:0]   sram_wdata;  // DUT → TB
  logic [DataWidth/8-1:0] sram_be;     // DUT → TB
  logic                   sram_gnt;    // TB → DUT
  logic [DataWidth-1:0]   sram_rdata;  // TB → DUT   (ROLLE B liefert Lesedaten)

  logic [DataWidth-1:0]   mem [0:255];      // SRAM-Speichermodell
  logic [DataWidth-1:0]   read_data [0:3];  // hier sammeln wir die gelesenen Woerter

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

  // ── Takt: 10 ns ──
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ══════════════════════════════════════════════════════════
  // ROLLE B — fake SRAM:  gnt=1,  Write + Read (1 Takt Latenz)
  // ══════════════════════════════════════════════════════════
  assign sram_gnt = 1'b1;

  always_ff @(posedge clk) begin
    if (sram_req && sram_we && sram_gnt)        // WRITE
      mem[sram_addr >> 2] <= sram_wdata;
    if (sram_req && !sram_we)                   // READ: Daten naechsten Takt gueltig
      sram_rdata <= mem[sram_addr >> 2];
  end

  // ══════════════════════════════════════════════════════════
  // ROLLE A — Stimulus + Checks
  // ══════════════════════════════════════════════════════════
  initial begin
    // Init + Reset
    rst_ni    = 1'b0;
    burst_req = '0;
    for (int i = 0; i < 256; i++) mem[i] = 32'hDEAD_BEEF;
    repeat (3) @(posedge clk);
    rst_ni = 1'b1;
    @(posedge clk); #1;

    // ══ WRITE-BURST: CAFE0001..0004 nach 0x100..0x10C ══
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

    if (mem[32'h100>>2] !== 32'hCAFE_0001) $error("[TB] WR D0 wrong: %h", mem[32'h100>>2]);
    if (mem[32'h104>>2] !== 32'hCAFE_0002) $error("[TB] WR D1 wrong: %h", mem[32'h104>>2]);
    if (mem[32'h108>>2] !== 32'hCAFE_0003) $error("[TB] WR D2 wrong: %h", mem[32'h108>>2]);
    if (mem[32'h10C>>2] !== 32'hCAFE_0004) $error("[TB] WR D3 wrong: %h", mem[32'h10C>>2]);
    $display("[TB] WRITE check done @ %0t", $time);

    // ══ READ-BURST: dieselben 4 Woerter von 0x100 zurueck lesen ══
    burst_req.hdr.start_addr = 32'h0000_0100;
    burst_req.hdr.blen       = 8'd3;
    burst_req.hdr.we         = 1'b0;          // READ
    burst_req.hdr_valid      = 1'b1;
    burst_req.rready         = 1'b1;          // iDMA immer abnahmebereit
    @(posedge clk); #1;
    burst_req.hdr_valid      = 1'b0;

    // 4 zurueckkommende Woerter einsammeln (jeweils im READ_DATA-Takt, wenn rvalid)
    for (int k = 0; k < 4; k++) begin
      while (!burst_rsp.rvalid) @(posedge clk);   // READ_ADDR-Takte ueberspringen
      read_data[k] = burst_rsp.rdata;             // im READ_DATA-Takt greifen
      @(posedge clk); #1;
    end
    burst_req.rready = 1'b0;

    if (read_data[0] !== 32'hCAFE_0001) $error("[TB] RD W0 wrong: %h", read_data[0]);
    if (read_data[1] !== 32'hCAFE_0002) $error("[TB] RD W1 wrong: %h", read_data[1]);
    if (read_data[2] !== 32'hCAFE_0003) $error("[TB] RD W2 wrong: %h", read_data[2]);
    if (read_data[3] !== 32'hCAFE_0004) $error("[TB] RD W3 wrong: %h", read_data[3]);
    $display("[TB] READ check done @ %0t  (no [TB]-Errors = write+read both ok)", $time);

    $finish;
  end

  // ── Waveform-Dump ──
  initial begin
    $dumpfile("tb_burst_endpoint.vcd");
    $dumpvars(0, tb_burst_endpoint);
  end

endmodule
