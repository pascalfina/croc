// ════════════════════════════════════════════════════════════════════════
// TB 1:  burst_compressor  ISOLIERT
//   linke Seite : iDMA-Modell  (Beats, gnt-Handshake pro Wort, rvalid-Empfang)
//   rechte Seite: fake-Endpoint (spricht burst-Protokoll wie der echte:
//                 hdr_gnt, wready + Write-Quittung, Read mit 1-Takt-Latenz)
//
//   Verifiziert die PROTOKOLL-Korrektheit des Compressors:
//     - Header korrekt gesendet            (Zwischensignal burst_req.hdr)
//     - Write: wdata-Stream stimmt
//     - Read : beat_rdata-Passthrough stimmt
//     - OBI-Regel pro Burst:  #beat_gnt == #beat_rvalid
//
//   Run: iverilog -g2012 -o sim_c burst_pkg.sv burst_compressor.sv tb_burst_compressor.sv && vvp sim_c
// ════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_burst_compressor import burst_pkg::*; ();

  logic clk, rst_ni;
  int   errors;

  // ─── iDMA-Beat-Seite (TB treibt) ───
  logic                     beat_valid, beat_we, beat_bfirst, beat_blast;
  logic [AddrWidth-1:0]     beat_addr;
  logic [DataWidth-1:0]     beat_wdata;
  logic [BurstLenWidth-1:0] beat_blen;
  logic                     beat_gnt;
  logic [DataWidth-1:0]     beat_rdata;
  logic                     beat_rvalid;

  // ─── Protokoll-Seite (DUT ↔ fake-Endpoint) ───
  burst_req_t burst_req;
  burst_rsp_t burst_rsp;

  // Muster: Read-Wort an Byte-Adresse A  ==  RDATA_BASE + A
  localparam logic [31:0] RDATA_BASE = 32'hC0DE_0000;
  // Muster: Write-Wort an Byte-Adresse A ==  WDATA_BASE + A
  localparam logic [31:0] WDATA_BASE = 32'hAA00_0000;

  // ─── DUT ───
  burst_compressor i_dut (
    .clk_i(clk), .rst_ni(rst_ni),
    .beat_valid_i(beat_valid), .beat_gnt_o(beat_gnt),
    .beat_addr_i(beat_addr), .beat_wdata_i(beat_wdata), .beat_we_i(beat_we),
    .beat_bfirst_i(beat_bfirst), .beat_blast_i(beat_blast), .beat_blen_i(beat_blen),
    .beat_rdata_o(beat_rdata), .beat_rvalid_o(beat_rvalid),
    .burst_req_o(burst_req), .burst_rsp_i(burst_rsp)
  );

  initial clk = 0;  always #5 clk = ~clk;

  // ══════════════════════════════════════════════════════════════════
  // FAKE-ENDPOINT  — spricht das burst-Protokoll wie der echte Endpoint
  //   IDLE  : hdr_gnt=1 wenn hdr_valid
  //   WRITE : wready=1 pro Wort,  rvalid (Quittung) 1 Takt spaeter
  //   READ  : 1 Takt Adress-Latenz, dann rvalid+rdata (Muster), bei rready weiter
  // ══════════════════════════════════════════════════════════════════
  typedef enum logic [1:0] {FE_IDLE, FE_WR, FE_RADDR, FE_RDATA} fe_t;
  fe_t fe_q, fe_d;
  logic [BurstLenWidth-1:0] fe_blen_q, fe_blen_d;
  logic [AddrWidth-1:0]     fe_addr_q, fe_addr_d;
  logic                     fe_wack_q, fe_wack_d;

  always_comb begin
    burst_rsp = '0;
    fe_d = fe_q;  fe_blen_d = fe_blen_q;  fe_addr_d = fe_addr_q;  fe_wack_d = 1'b0;
    case (fe_q)
      FE_IDLE: if (burst_req.hdr_valid) begin
                 burst_rsp.hdr_gnt = 1'b1;
                 fe_addr_d = burst_req.hdr.start_addr;
                 fe_blen_d = burst_req.hdr.blen;
                 if (burst_req.hdr.we) fe_d = FE_WR;
                 else                  fe_d = FE_RADDR;
               end
      FE_WR:   if (burst_req.wvalid) begin
                 burst_rsp.wready = 1'b1;
                 fe_wack_d        = 1'b1;                 // Quittung naechsten Takt
                 fe_addr_d        = fe_addr_q + 4;
                 if (fe_blen_q == 0) fe_d = FE_IDLE;
                 else                fe_blen_d = fe_blen_q - 1;
               end
      FE_RADDR: fe_d = FE_RDATA;                          // 1 Takt Latenz wie SRAM
      FE_RDATA: begin
                 burst_rsp.rvalid = 1'b1;
                 burst_rsp.rdata  = RDATA_BASE + fe_addr_q;
                 if (burst_req.rready) begin
                   if (fe_blen_q == 0) fe_d = FE_IDLE;
                   else begin fe_addr_d = fe_addr_q + 4; fe_blen_d = fe_blen_q - 1; fe_d = FE_RADDR; end
                 end
               end
    endcase
    if (fe_wack_q) burst_rsp.rvalid = 1'b1;               // Write-Quittung (state-unabhaengig)
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin fe_q<=FE_IDLE; fe_blen_q<=0; fe_addr_q<=0; fe_wack_q<=0; end
    else         begin fe_q<=fe_d; fe_blen_q<=fe_blen_d; fe_addr_q<=fe_addr_d; fe_wack_q<=fe_wack_d; end
  end

  // ══════════════════════════════════════════════════════════════════
  // MONITORE  (laufen die ganze Zeit)
  // ══════════════════════════════════════════════════════════════════
  // (a) gnt- + rvalid-Zaehler  → OBI: pro Burst muss #gnt == #rvalid sein
  int gnt_cnt, rvalid_cnt;
  always @(posedge clk) if (rst_ni) begin
    if (beat_gnt)    gnt_cnt    <= gnt_cnt    + 1;
    if (beat_rvalid) rvalid_cnt <= rvalid_cnt + 1;
  end

  // (b) gesendete wdata (Write) + empfangene rdata (Read) mitschreiben
  logic [DataWidth-1:0] wsent [0:31];  int wsent_n;
  logic [DataWidth-1:0] rrecv [0:31];  int rrecv_n;
  always @(posedge clk) if (rst_ni) begin
    if (burst_req.wvalid && burst_rsp.wready) begin wsent[wsent_n] <= burst_req.wdata; wsent_n <= wsent_n + 1; end
    if (beat_rvalid)                          begin rrecv[rrecv_n] <= beat_rdata;      rrecv_n <= rrecv_n + 1; end
  end

  // (c) Header-Capture  → Zwischensignal pruefen
  burst_hdr_t hdr_seen;
  always @(posedge clk) if (rst_ni && burst_req.hdr_valid && burst_rsp.hdr_gnt) hdr_seen <= burst_req.hdr;

  // ══════════════════════════════════════════════════════════════════
  // iDMA-MODELL
  // ══════════════════════════════════════════════════════════════════
  // Write-Burst: N Beats, je auf gnt warten (wie echter iDMA-Write-Port)
  task automatic idma_write(input [31:0] start, input [7:0] blen);
    for (int k = 0; k <= blen; k++) begin
      beat_valid=1; beat_we=1; beat_addr=start+(k<<2); beat_wdata=WDATA_BASE+(start+(k<<2));
      beat_bfirst=(k==0); beat_blast=(k==blen); beat_blen=blen;
      do @(posedge clk); while (!beat_gnt);
      #1;
    end
    beat_valid=0; beat_we=0; beat_bfirst=0; beat_blast=0;
  endtask

  // Read-Burst: N Read-Requests, je auf gnt warten. Daten kommen entkoppelt
  // ueber den rrecv-Monitor (genau wie der echte iDMA: A-Phase != R-Phase)
  task automatic idma_read(input [31:0] start, input [7:0] blen);
    for (int k = 0; k <= blen; k++) begin
      beat_valid=1; beat_we=0; beat_addr=start+(k<<2);
      beat_bfirst=(k==0); beat_blast=(k==blen); beat_blen=blen;
      do @(posedge clk); while (!beat_gnt);
      #1;
    end
    beat_valid=0; beat_bfirst=0; beat_blast=0;
  endtask

  task automatic chk(input logic cond, input string msg);
    if (!cond) begin $error("[C] FAIL: %s", msg); errors++; end
  endtask

  // ══════════════════════════════════════════════════════════════════
  // STIMULUS
  // ══════════════════════════════════════════════════════════════════
  int gbase, rbase, wbase, rcbase;
  initial begin
    errors=0; rst_ni=0;
    beat_valid=0; beat_we=0; beat_addr=0; beat_wdata=0; beat_bfirst=0; beat_blast=0; beat_blen=0;
    gnt_cnt=0; rvalid_cnt=0; wsent_n=0; rrecv_n=0;
    repeat(3) @(posedge clk); rst_ni=1; @(posedge clk); #1;

    // ─── Test 1: WRITE-Burst, 4 Woerter (blen=3) ───
    $display("[C] Test 1: write-burst blen=3");
    gbase=gnt_cnt; rbase=rvalid_cnt; wbase=wsent_n;
    idma_write(32'h100, 8'd3);
    repeat(4) @(posedge clk);
    chk(hdr_seen.start_addr==32'h100 && hdr_seen.blen==3 && hdr_seen.we==1, "T1 Header");
    chk(wsent_n-wbase == 4, "T1 #wdata==4");
    for (int k=0;k<4;k++) chk(wsent[wbase+k]==WDATA_BASE+(32'h100+(k<<2)), $sformatf("T1 wdata%0d",k));
    chk(gnt_cnt-gbase    == 4, "T1 #gnt==4");
    chk(rvalid_cnt-rbase == 4, "T1 #rvalid==4 (Write-Quittungen)");

    // ─── Test 2: READ-Burst, 4 Woerter (blen=3) ───
    $display("[C] Test 2: read-burst blen=3");
    gbase=gnt_cnt; rbase=rvalid_cnt; rcbase=rrecv_n;
    idma_read(32'h200, 8'd3);
    repeat(8) @(posedge clk);
    chk(hdr_seen.start_addr==32'h200 && hdr_seen.blen==3 && hdr_seen.we==0, "T2 Header");
    chk(rrecv_n-rcbase == 4, "T2 #rdata==4");
    for (int k=0;k<4;k++) chk(rrecv[rcbase+k]==RDATA_BASE+(32'h200+(k<<2)), $sformatf("T2 rdata%0d",k));
    chk(gnt_cnt-gbase    == 4, "T2 #gnt==4 (Read-Requests)");
    chk(rvalid_cnt-rbase == 4, "T2 #rvalid==4");

    // ─── Test 3: Single-Beat WRITE (blen=0) ───
    $display("[C] Test 3: single-beat write");
    gbase=gnt_cnt; rbase=rvalid_cnt; wbase=wsent_n;
    idma_write(32'h300, 8'd0);
    repeat(4) @(posedge clk);
    chk(wsent_n-wbase==1 && wsent[wbase]==WDATA_BASE+32'h300, "T3 wdata");
    chk(gnt_cnt-gbase==1 && rvalid_cnt-rbase==1, "T3 #gnt==#rvalid==1");

    // ─── Test 4: Single-Beat READ (blen=0) ───
    $display("[C] Test 4: single-beat read");
    gbase=gnt_cnt; rbase=rvalid_cnt; rcbase=rrecv_n;
    idma_read(32'h400, 8'd0);
    repeat(6) @(posedge clk);
    chk(rrecv_n-rcbase==1 && rrecv[rcbase]==RDATA_BASE+32'h400, "T4 rdata");
    chk(gnt_cnt-gbase==1 && rvalid_cnt-rbase==1, "T4 #gnt==#rvalid==1");

    // ─── Test 5: zwei Write-Bursts back-to-back ───
    $display("[C] Test 5: back-to-back write-bursts");
    gbase=gnt_cnt; rbase=rvalid_cnt;
    idma_write(32'h500, 8'd1);
    idma_write(32'h600, 8'd1);
    repeat(4) @(posedge clk);
    chk(gnt_cnt-gbase==4 && rvalid_cnt-rbase==4, "T5 2x2 Woerter, #gnt==#rvalid==4");

    if (errors==0) $display("[C] ============  COMPRESSOR TB PASSED  ============");
    else           $display("[C] ============  %0d ERROR(S)  ============", errors);
    $finish;
  end

  // ── Watchdog: zeigt beim Haengen den genauen Zustand ──
  initial begin
    #50000;
    $display("[C] !!! STUCK @ %0t", $time);
    $display("    Compressor: state_q=%0d count_q=%0d", i_dut.state_q, i_dut.count_q);
    $display("    fake-EP   : fe_q=%0d fe_blen_q=%0d fe_addr_q=%08x", fe_q, fe_blen_q, fe_addr_q);
    $display("    beats     : valid=%b gnt=%b we=%b bfirst=%b blast=%b blen=%0d",
             beat_valid, beat_gnt, beat_we, beat_bfirst, beat_blast, beat_blen);
    $display("    burst_req : hdr_valid=%b wvalid=%b wdata=%08x rready=%b",
             burst_req.hdr_valid, burst_req.wvalid, burst_req.wdata, burst_req.rready);
    $display("    burst_rsp : hdr_gnt=%b wready=%b rvalid=%b rdata=%08x",
             burst_rsp.hdr_gnt, burst_rsp.wready, burst_rsp.rvalid, burst_rsp.rdata);
    $finish;
  end

  initial begin
    $dumpfile("tb_burst_compressor.vcd");
    $dumpvars(0, tb_burst_compressor);
  end

endmodule
