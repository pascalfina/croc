// Contention testbench for burst_endpoint (Method 2)

`timescale 1ns/1ps

module tb_burst_contention import burst_pkg::*; ();

  // ── Signale ──
  logic                   clk, rst_ni;

  burst_req_t             burst_req;
  burst_rsp_t             burst_rsp;

  logic                   sram_req, sram_we;
  logic [AddrWidth-1:0]   sram_addr;
  logic [DataWidth-1:0]   sram_wdata;
  logic [DataWidth/8-1:0] sram_be;
  logic                   sram_gnt;
  logic [DataWidth-1:0]   sram_rdata;

  // CPU-Seite
  logic                   cpu_req, cpu_we;
  logic [AddrWidth-1:0]   cpu_addr;
  logic [DataWidth-1:0]   cpu_wdata;
  logic [DataWidth/8-1:0] cpu_be;
  logic                   cpu_gnt;
  logic [DataWidth-1:0]   cpu_rdata;
  logic                   cpu_rvalid;

  logic [DataWidth-1:0]   mem [0:1023];
  int                     errors;
  logic [DataWidth-1:0]   rd;          // collector for CPU-Reads

  localparam logic [1:0]  ST_IDLE = 2'd0;   // IDLE 

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
    .sram_rdata_i ( sram_rdata ),
    .cpu_req_i    ( cpu_req    ),
    .cpu_we_i     ( cpu_we     ),
    .cpu_addr_i   ( cpu_addr   ),
    .cpu_wdata_i  ( cpu_wdata  ),
    .cpu_be_i     ( cpu_be     ),
    .cpu_gnt_o    ( cpu_gnt    ),
    .cpu_rdata_o  ( cpu_rdata  ),
    .cpu_rvalid_o ( cpu_rvalid )
  );

  // ── Takt ──
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ── Fake-SRAM: immer bereit, Write + Read (1 Takt Latenz) ──
  assign sram_gnt = 1'b1;
  always_ff @(posedge clk) begin
    if (sram_req && sram_we)   mem[sram_addr >> 2] <= sram_wdata;
    if (sram_req && !sram_we)  sram_rdata          <= mem[sram_addr >> 2];
  end

  // ══════════════════════════════════════════════════════════
  // LOCK-MONITOR  (laeuft die GANZE Zeit, ueber alle Tests)
  //   waehrend ein Burst laeuft (state != IDLE) darf cpu_gnt NIE 1 sein
  // ══════════════════════════════════════════════════════════
  always @(posedge clk) begin
    if (rst_ni && (i_dut.state_q !== ST_IDLE) && cpu_gnt) begin
      $error("[TB] LOCK VERLETZT @ %0t: cpu_gnt=1 obwohl Burst laeuft (state=%0d)",
             $time, i_dut.state_q);
      errors++;
    end
  end

  // ══════════════════════════════════════════════════════════
  // Helper-Tasks
  // ══════════════════════════════════════════════════════════

  // iDMA Write-Burst: schreibt Muster (A0000000 + byte-addr) an start..start+blen
  task automatic idma_write_burst(input logic [31:0] start, input logic [7:0] blen);
    burst_req.hdr.start_addr = start;
    burst_req.hdr.blen       = blen;
    burst_req.hdr.we         = 1'b1;
    burst_req.hdr_valid      = 1'b1;
    @(posedge clk); #1;
    burst_req.hdr_valid      = 1'b0;
    for (int k = 0; k <= blen; k++) begin
      burst_req.wvalid = 1'b1;
      burst_req.wdata  = 32'hA000_0000 + start + (k << 2);
      @(posedge clk); #1;
    end
    burst_req.wvalid = 1'b0;
  endtask

  // iDMA Read-Burst: liest start..start+blen und prueft gegen mem
  task automatic idma_read_burst(input logic [31:0] start, input logic [7:0] blen);
    logic [31:0] exp;
    burst_req.hdr.start_addr = start;
    burst_req.hdr.blen       = blen;
    burst_req.hdr.we         = 1'b0;
    burst_req.hdr_valid      = 1'b1;
    burst_req.rready         = 1'b1;
    @(posedge clk); #1;
    burst_req.hdr_valid      = 1'b0;
    for (int k = 0; k <= blen; k++) begin
      while (!burst_rsp.rvalid) @(posedge clk);
      exp = mem[(start + (k << 2)) >> 2];
      if (burst_rsp.rdata !== exp) begin
        $error("[TB] iDMA-read W%0d @ %08x: got %08x exp %08x",
               k, start + (k << 2), burst_rsp.rdata, exp);
        errors++;
      end
      @(posedge clk); #1;
    end
    burst_req.rready = 1'b0;
  endtask

  // CPU Write: draengelt, bis durchgekommen (wartet auf gnt)
  task automatic cpu_write(input logic [31:0] addr, input logic [31:0] data);
    cpu_req = 1'b1; cpu_we = 1'b1; cpu_addr = addr; cpu_wdata = data; cpu_be = '1;
    do @(posedge clk); while (!cpu_gnt);
    #1; cpu_req = 1'b0; cpu_we = 1'b0;
  endtask

  // CPU Read: draengelt bis durch, holt rdata (1 Takt nach Annahme)
  task automatic cpu_read(input logic [31:0] addr, output logic [31:0] data);
    cpu_req = 1'b1; cpu_we = 1'b0; cpu_addr = addr; cpu_be = '1;
    do @(posedge clk); while (!cpu_gnt);   // Read angenommen (Flanke F)
    #1; cpu_req = 1'b0;
    // rvalid + rdata sind jetzt (1 Takt nach F) gueltig
    if (!cpu_rvalid) begin
      $error("[TB] cpu_read @ %08x: rvalid fehlt @ %0t", addr, $time);
      errors++;
    end
    data = cpu_rdata;
  endtask

  // Check-Helper
  task automatic check(input logic [31:0] got, input logic [31:0] exp, input string name);
    if (got !== exp) begin
      $error("[TB] %s: got %08x exp %08x", name, got, exp);
      errors++;
    end
  endtask

  // ══════════════════════════════════════════════════════════
  // Stimulus
  // ══════════════════════════════════════════════════════════
  initial begin
    errors    = 0;
    rst_ni    = 1'b0;
    burst_req = '0;
    cpu_req   = 1'b0; cpu_we = 1'b0; cpu_addr = '0; cpu_wdata = '0; cpu_be = '0;
    for (int i = 0; i < 1024; i++) mem[i] = 32'hDEAD_BEEF;
    repeat (3) @(posedge clk);
    rst_ni = 1'b1;
    @(posedge clk); #1;

    // ── Test 1: CPU-Write in IDLE (kein Burst) → muss durchkommen ──
    $display("[TB] Test 1: CPU write in IDLE");
    cpu_write(32'h200, 32'h1111_1111);
    repeat (2) @(posedge clk);
    check(mem[32'h200>>2], 32'h1111_1111, "T1 CPU-write");

    // ── Test 2: CPU-Read in IDLE → rvalid + richtige Daten ──
    $display("[TB] Test 2: CPU read in IDLE");
    cpu_read(32'h200, rd);
    check(rd, 32'h1111_1111, "T2 CPU-read");

    // ── Test 3: WRITE-Burst + CPU draengelt parallel (Contention!) ──
    $display("[TB] Test 3: write-burst + CPU contention");
    fork
      idma_write_burst(32'h100, 8'd3);       // iDMA-Burst 4 Woerter
      cpu_write(32'h300, 32'hBBBB_BBBB);     // CPU will rein (wartet bis nach Burst)
    join
    repeat (2) @(posedge clk);
    // Burst-Daten korrekt?
    check(mem[32'h100>>2], 32'hA000_0100, "T3 burst W0");
    check(mem[32'h104>>2], 32'hA000_0104, "T3 burst W1");
    check(mem[32'h108>>2], 32'hA000_0108, "T3 burst W2");
    check(mem[32'h10C>>2], 32'hA000_010C, "T3 burst W3");
    // CPU kam (nach dem Burst) durch?
    check(mem[32'h300>>2], 32'hBBBB_BBBB, "T3 CPU-write");

    // ── Test 4: READ-Burst + CPU draengelt parallel ──
    $display("[TB] Test 4: read-burst + CPU contention");
    fork
      idma_read_burst(32'h100, 8'd3);        // liest die eben geschriebenen Daten + prueft
      cpu_write(32'h304, 32'hCCCC_CCCC);     // CPU draengelt
    join
    repeat (2) @(posedge clk);
    check(mem[32'h304>>2], 32'hCCCC_CCCC, "T4 CPU-write");

    // ── Test 5: Single-Beat-Burst (blen=0) + CPU draengelt ──
    $display("[TB] Test 5: single-beat burst + CPU contention");
    fork
      idma_write_burst(32'h400, 8'd0);       // genau 1 Wort
      cpu_write(32'h308, 32'hDDDD_DDDD);
    join
    repeat (2) @(posedge clk);
    check(mem[32'h400>>2], 32'hA000_0400, "T5 burst W0");
    check(mem[32'h308>>2], 32'hDDDD_DDDD, "T5 CPU-write");

    // ── Test 6: Burst-Vorrang — Header und cpu_req exakt gleichzeitig ──
    $display("[TB] Test 6: burst priority (header vs cpu_req same cycle)");
    // CPU haelt req dauerhaft an, dann kommt der Burst-Header im selben Takt
    cpu_req = 1'b1; cpu_we = 1'b1; cpu_addr = 32'h500; cpu_wdata = 32'hEEEE_EEEE; cpu_be = '1;
    fork
      idma_write_burst(32'h180, 8'd1);       // 2-Wort-Burst, startet sofort
    join
    // CPU darf erst NACH dem Burst durch (das Lock haelt den dauerhaften cpu_req)
    do @(posedge clk); while (!cpu_gnt);
    #1; cpu_req = 1'b0; cpu_we = 1'b0;
    repeat (2) @(posedge clk);
    check(mem[32'h180>>2], 32'hA000_0180, "T6 burst W0");
    check(mem[32'h184>>2], 32'hA000_0184, "T6 burst W1");
    check(mem[32'h500>>2], 32'hEEEE_EEEE, "T6 CPU-write");

    // ── Ergebnis ──
    repeat (3) @(posedge clk);
    if (errors == 0)
      $display("[TB] =====================  ALL TESTS PASSED  =====================");
    else
      $display("[TB] =====================  %0d ERROR(S)  =====================", errors);
    $finish;
  end

  // ── Waveform-Dump ──
  initial begin
    $dumpfile("tb_burst_contention.vcd");
    $dumpvars(0, tb_burst_contention);
  end

endmodule
