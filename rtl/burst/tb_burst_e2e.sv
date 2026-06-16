// ════════════════════════════════════════════════════════════════════════
// TB 2:  END-TO-END   iDMA → Compressor → Endpoint → SRAM   (+ CPU am Endpoint)
//
//   Modelliert wie im echten Croc:
//     - iDMA  : Beats mit gnt-Handshake pro Wort (Write) / N Read-Requests,
//               Daten/Quittungen entkoppelt empfangen
//     - SRAM  : single-port, Latency=1, gnt=1  (wie tc_sram + bank_gnt)
//     - CPU   : OBI-Manager am cpu_*-Port (req/gnt, rvalid 1 Takt spaeter)
//
//   Verifiziert:
//     - Write-Burst landet korrekt in der SRAM
//     - Read-Burst liefert exakt die geschriebenen Daten zurueck
//     - OBI pro Burst:  #beat_gnt == #beat_rvalid
//     - CPU-Pfad (write/read) korrekt
//     - LOCK: solange Endpoint != IDLE bekommt die CPU KEIN gnt
//     - Zwischensignale: SRAM-Schreibadresse/-daten waehrend des Bursts
//
//   Run: iverilog -g2012 -o sim_e burst_pkg.sv burst_compressor.sv burst_endpoint.sv tb_burst_e2e.sv && vvp sim_e
// ════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_burst_e2e import burst_pkg::*; ();

  logic clk, rst_ni;
  int   errors;

  localparam logic [1:0] EP_IDLE = 2'd0;          // Endpoint-State IDLE (fuer Lock-Monitor)
  localparam logic [31:0] WDATA_BASE = 32'hAA00_0000;

  // ─── iDMA-Beats (TB → Compressor) ───
  logic                     beat_valid, beat_we, beat_bfirst, beat_blast;
  logic [AddrWidth-1:0]     beat_addr;
  logic [DataWidth-1:0]     beat_wdata;
  logic [BurstLenWidth-1:0] beat_blen;
  logic                     beat_gnt;
  logic [DataWidth-1:0]     beat_rdata;
  logic                     beat_rvalid;

  // ─── Compressor ↔ Endpoint ───
  burst_req_t c2e_req;
  burst_rsp_t e2c_rsp;

  // ─── Endpoint ↔ SRAM ───
  logic                   sram_req, sram_we;
  logic [AddrWidth-1:0]   sram_addr;
  logic [DataWidth-1:0]   sram_wdata, sram_rdata;
  logic [DataWidth/8-1:0] sram_be;
  logic                   sram_gnt;
  logic [DataWidth-1:0]   mem [0:1023];

  // ─── CPU (TB → Endpoint) ───
  logic                   cpu_req, cpu_we;
  logic [AddrWidth-1:0]   cpu_addr;
  logic [DataWidth-1:0]   cpu_wdata, cpu_rdata;
  logic [DataWidth/8-1:0] cpu_be;
  logic                   cpu_gnt, cpu_rvalid;

  // ══════════════════════════════════════════════════════════════════
  // DUTs
  // ══════════════════════════════════════════════════════════════════
  burst_compressor i_comp (
    .clk_i(clk), .rst_ni(rst_ni),
    .beat_valid_i(beat_valid), .beat_gnt_o(beat_gnt),
    .beat_addr_i(beat_addr), .beat_wdata_i(beat_wdata), .beat_we_i(beat_we),
    .beat_bfirst_i(beat_bfirst), .beat_blast_i(beat_blast), .beat_blen_i(beat_blen),
    .beat_rdata_o(beat_rdata), .beat_rvalid_o(beat_rvalid),
    .burst_req_o(c2e_req), .burst_rsp_i(e2c_rsp)
  );

  burst_endpoint i_ep (
    .clk_i(clk), .rst_ni(rst_ni),
    .burst_req_i(c2e_req), .burst_rsp_o(e2c_rsp),
    .sram_req_o(sram_req), .sram_we_o(sram_we), .sram_addr_o(sram_addr),
    .sram_wdata_o(sram_wdata), .sram_be_o(sram_be),
    .sram_gnt_i(sram_gnt), .sram_rdata_i(sram_rdata),
    .cpu_req_i(cpu_req), .cpu_we_i(cpu_we), .cpu_addr_i(cpu_addr),
    .cpu_wdata_i(cpu_wdata), .cpu_be_i(cpu_be),
    .cpu_gnt_o(cpu_gnt), .cpu_rdata_o(cpu_rdata), .cpu_rvalid_o(cpu_rvalid)
  );

  initial clk = 0;  always #5 clk = ~clk;

  // ─── fake-SRAM: single-port, gnt=1, Latency=1 (wie tc_sram im Croc) ───
  assign sram_gnt = 1'b1;
  always_ff @(posedge clk) begin
    if (sram_req && sram_we)  mem[sram_addr>>2] <= sram_wdata;
    if (sram_req && !sram_we) sram_rdata        <= mem[sram_addr>>2];
  end

  // ══════════════════════════════════════════════════════════════════
  // MONITORE
  // ══════════════════════════════════════════════════════════════════
  // (a) #gnt / #rvalid am iDMA-Port  (OBI: pro Burst gleich)
  int gnt_cnt, rvalid_cnt;
  always @(posedge clk) if (rst_ni) begin
    if (beat_gnt)    gnt_cnt    <= gnt_cnt    + 1;
    if (beat_rvalid) rvalid_cnt <= rvalid_cnt + 1;
  end

  // (b) empfangene Read-Daten am iDMA-Port
  logic [DataWidth-1:0] rrecv [0:31];  int rrecv_n;
  always @(posedge clk) if (rst_ni && beat_rvalid) begin rrecv[rrecv_n] <= beat_rdata; rrecv_n <= rrecv_n + 1; end

  // (c) LOCK-Monitor: solange Burst laeuft (Endpoint != IDLE) NIE cpu_gnt
  always @(posedge clk) if (rst_ni && (i_ep.state_q !== EP_IDLE) && cpu_gnt) begin
    $error("[E2E] LOCK VERLETZT @ %0t: cpu_gnt waehrend Burst (state=%0d)", $time, i_ep.state_q);
    errors++;
  end

  // (d) Zwischensignal-Check: bei jedem SRAM-Write muss be voll sein (volle Woerter)
  always @(posedge clk) if (rst_ni && sram_req && sram_we && sram_be !== 4'b1111) begin
    $error("[E2E] SRAM-Write mit be=%b (erwartet 1111) @ %0t", sram_be, $time);
    errors++;
  end

  // ══════════════════════════════════════════════════════════════════
  // MODELLE: iDMA + CPU
  // ══════════════════════════════════════════════════════════════════
  task automatic idma_write(input [31:0] start, input [7:0] blen);
    for (int k = 0; k <= blen; k++) begin
      beat_valid=1; beat_we=1; beat_addr=start+(k<<2); beat_wdata=WDATA_BASE+(start+(k<<2));
      beat_bfirst=(k==0); beat_blast=(k==blen); beat_blen=blen;
      do @(posedge clk); while (!beat_gnt);
      #1;
    end
    beat_valid=0; beat_we=0; beat_bfirst=0; beat_blast=0;
  endtask

  task automatic idma_read(input [31:0] start, input [7:0] blen);
    for (int k = 0; k <= blen; k++) begin
      beat_valid=1; beat_we=0; beat_addr=start+(k<<2);
      beat_bfirst=(k==0); beat_blast=(k==blen); beat_blen=blen;
      do @(posedge clk); while (!beat_gnt);
      #1;
    end
    beat_valid=0; beat_bfirst=0; beat_blast=0;
  endtask

  task automatic cpu_write(input [31:0] addr, input [31:0] data);
    cpu_req=1; cpu_we=1; cpu_addr=addr; cpu_wdata=data; cpu_be='1;
    do @(posedge clk); while (!cpu_gnt);
    #1; cpu_req=0; cpu_we=0;
  endtask

  task automatic cpu_read(input [31:0] addr, output [31:0] data);
    cpu_req=1; cpu_we=0; cpu_addr=addr; cpu_be='1;
    do @(posedge clk); while (!cpu_gnt);     // Read angenommen
    #1; cpu_req=0;
    if (!cpu_rvalid) begin $error("[E2E] cpu_read @ %08x: rvalid fehlt", addr); errors++; end
    data = cpu_rdata;                         // rvalid+rdata 1 Takt nach gnt
  endtask

  task automatic chk(input logic cond, input string msg);
    if (!cond) begin $error("[E2E] FAIL: %s", msg); errors++; end
  endtask

  // ══════════════════════════════════════════════════════════════════
  // STIMULUS
  // ══════════════════════════════════════════════════════════════════
  int gbase, rbase, rcbase;
  logic [31:0] rd;
  initial begin
    errors=0; rst_ni=0;
    beat_valid=0; beat_we=0; beat_addr=0; beat_wdata=0; beat_bfirst=0; beat_blast=0; beat_blen=0;
    cpu_req=0; cpu_we=0; cpu_addr=0; cpu_wdata=0; cpu_be=0;
    gnt_cnt=0; rvalid_cnt=0; rrecv_n=0;
    for (int i=0;i<1024;i++) mem[i]=32'hDEAD_BEEF;
    repeat(3) @(posedge clk); rst_ni=1; @(posedge clk); #1;

    // ─── Test 1: WRITE-Burst durch die GANZE Kette ───
    $display("[E2E] Test 1: write-burst 0x100, 4 Woerter");
    gbase=gnt_cnt; rbase=rvalid_cnt;
    idma_write(32'h100, 8'd3);
    repeat(4) @(posedge clk);
    for (int k=0;k<4;k++)
      chk(mem[(32'h100+(k<<2))>>2]==WDATA_BASE+(32'h100+(k<<2)), $sformatf("T1 SRAM[%0d]",k));
    chk(gnt_cnt-gbase==4 && rvalid_cnt-rbase==4, "T1 #gnt==#rvalid==4");

    // ─── Test 2: READ-Burst — muss dieselben Daten zurueckgeben ───
    $display("[E2E] Test 2: read-burst 0x100, 4 Woerter");
    gbase=gnt_cnt; rbase=rvalid_cnt; rcbase=rrecv_n;
    idma_read(32'h100, 8'd3);
    repeat(8) @(posedge clk);
    chk(rrecv_n-rcbase==4, "T2 #rdata==4");
    for (int k=0;k<4;k++)
      chk(rrecv[rcbase+k]==WDATA_BASE+(32'h100+(k<<2)), $sformatf("T2 rdata[%0d]",k));
    chk(gnt_cnt-gbase==4 && rvalid_cnt-rbase==4, "T2 #gnt==#rvalid==4");

    // ─── Test 3: CPU write + read (in IDLE, kein Burst) ───
    $display("[E2E] Test 3: CPU write/read");
    cpu_write(32'h280, 32'h1234_5678);
    repeat(2) @(posedge clk);
    chk(mem[32'h280>>2]==32'h1234_5678, "T3 CPU-write in SRAM");
    cpu_read(32'h280, rd);
    chk(rd==32'h1234_5678, "T3 CPU-read");

    // ─── Test 4: CONTENTION — Burst + CPU gleichzeitig, Lock muss halten ───
    $display("[E2E] Test 4: contention (burst + CPU), lock check");
    gbase=gnt_cnt; rbase=rvalid_cnt;
    fork
      idma_write(32'h180, 8'd3);          // 4-Wort-Burst
      cpu_write(32'h700, 32'hCAFE_BABE);  // CPU draengelt parallel
    join
    repeat(3) @(posedge clk);
    for (int k=0;k<4;k++)
      chk(mem[(32'h180+(k<<2))>>2]==WDATA_BASE+(32'h180+(k<<2)), $sformatf("T4 burst[%0d]",k));
    chk(mem[32'h700>>2]==32'hCAFE_BABE, "T4 CPU kam nach Burst durch");
    chk(gnt_cnt-gbase==4 && rvalid_cnt-rbase==4, "T4 #gnt==#rvalid==4 (Burst)");

    // ─── Test 5: Single-Beat Write + Read ───
    $display("[E2E] Test 5: single-beat write+read");
    gbase=gnt_cnt; rbase=rvalid_cnt; rcbase=rrecv_n;
    idma_write(32'h500, 8'd0);
    repeat(3) @(posedge clk);
    chk(mem[32'h500>>2]==WDATA_BASE+32'h500, "T5 SRAM single");
    idma_read(32'h500, 8'd0);
    repeat(5) @(posedge clk);
    chk(rrecv[rcbase]==WDATA_BASE+32'h500, "T5 read single");
    chk(gnt_cnt-gbase==2 && rvalid_cnt-rbase==2, "T5 1 write + 1 read → #gnt==#rvalid==2");

    if (errors==0) $display("[E2E] ============  END-TO-END TB PASSED  ============");
    else           $display("[E2E] ============  %0d ERROR(S)  ============", errors);
    $finish;
  end

  initial begin
    $dumpfile("tb_burst_e2e.vcd");
    $dumpvars(0, tb_burst_e2e);
  end

endmodule
