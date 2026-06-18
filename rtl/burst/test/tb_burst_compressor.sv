// ════════════════════════════════════════════════════════════════════════
// TB 1: burst_compressor ISOLIERT
// ════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_burst_compressor import burst_pkg::*; ();

  logic clk, rst_ni;
  int   errors;

  // iDMA-Beat-Seite
  logic                     beat_valid, beat_we, beat_bfirst, beat_blast;
  logic [AddrWidth-1:0]     beat_addr;
  logic [DataWidth-1:0]     beat_wdata;
  logic [BurstLenWidth-1:0] beat_blen;
  logic                     beat_gnt;
  logic [DataWidth-1:0]     beat_rdata;
  logic                     beat_rvalid;

  logic first_beat_dbg;
  assign first_beat_dbg = beat_valid & beat_bfirst;

  // Protokoll-Seite
  burst_req_t burst_req;

  // DUT bekommt burst_rsp, fake endpoint treibt burst_rsp_comb
  burst_rsp_t burst_rsp;
  burst_rsp_t burst_rsp_comb;

  // WICHTIG: bricht Zero-Time-Loop zwischen burst_req und burst_rsp
  assign #1 burst_rsp = burst_rsp_comb;

  localparam logic [31:0] RDATA_BASE = 32'hC0DE_0000;
  localparam logic [31:0] WDATA_BASE = 32'hAA00_0000;

  // DUT
  burst_compressor i_dut (
    .clk_i(clk),
    .rst_ni(rst_ni),

    .beat_valid_i(beat_valid),
    .beat_gnt_o(beat_gnt),
    .beat_addr_i(beat_addr),
    .beat_wdata_i(beat_wdata),
    .beat_we_i(beat_we),
    .beat_bfirst_i(beat_bfirst),
    .beat_blast_i(beat_blast),
    .beat_blen_i(beat_blen),
    .beat_rdata_o(beat_rdata),
    .beat_rvalid_o(beat_rvalid),

    .burst_req_o(burst_req),
    .burst_rsp_i(burst_rsp)
  );

  initial clk = 0;
  always #5 clk = ~clk;

  // ══════════════════════════════════════════════════════════════════
  // FAKE-ENDPOINT
  // ══════════════════════════════════════════════════════════════════

  typedef enum logic [1:0] {
    FE_IDLE,
    FE_WR,
    FE_RADDR,
    FE_RDATA
  } fe_t;

  fe_t fe_q, fe_d;

  logic [BurstLenWidth-1:0] fe_blen_q, fe_blen_d;
  logic [AddrWidth-1:0]     fe_addr_q, fe_addr_d;
  logic                     fe_wack_q, fe_wack_d;

  always @(*) begin
    burst_rsp_comb = '0;

    fe_d      = fe_q;
    fe_blen_d = fe_blen_q;
    fe_addr_d = fe_addr_q;
    fe_wack_d = 1'b0;

    case (fe_q)

      FE_IDLE: begin
        if (burst_req.hdr_valid) begin
          burst_rsp_comb.hdr_gnt = 1'b1;

          fe_addr_d = burst_req.hdr.start_addr;
          fe_blen_d = burst_req.hdr.blen;

          if (burst_req.hdr.we)
            fe_d = FE_WR;
          else
            fe_d = FE_RADDR;
        end
      end

      FE_WR: begin
        if (burst_req.wvalid) begin
          burst_rsp_comb.wready = 1'b1;

          fe_wack_d = 1'b1;
          fe_addr_d = fe_addr_q + 4;

          if (fe_blen_q == 0) begin
            fe_d = FE_IDLE;
          end else begin
            fe_blen_d = fe_blen_q - 1;
          end
        end
      end

      FE_RADDR: begin
        fe_d = FE_RDATA;
      end

      FE_RDATA: begin
        burst_rsp_comb.rvalid = 1'b1;
        burst_rsp_comb.rdata  = RDATA_BASE + fe_addr_q;

        if (burst_req.rready) begin
          if (fe_blen_q == 0) begin
            fe_d = FE_IDLE;
          end else begin
            fe_addr_d = fe_addr_q + 4;
            fe_blen_d = fe_blen_q - 1;
            fe_d      = FE_RADDR;
          end
        end
      end

      default: begin
        fe_d = FE_IDLE;
      end

    endcase

    if (fe_wack_q) begin
      burst_rsp_comb.rvalid = 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      fe_q      <= FE_IDLE;
      fe_blen_q <= '0;
      fe_addr_q <= '0;
      fe_wack_q <= 1'b0;
    end else begin
      fe_q      <= fe_d;
      fe_blen_q <= fe_blen_d;
      fe_addr_q <= fe_addr_d;
      fe_wack_q <= fe_wack_d;
    end
  end

  // ══════════════════════════════════════════════════════════════════
  // MONITORE
  // ══════════════════════════════════════════════════════════════════

  int gnt_cnt, rvalid_cnt;

  always @(posedge clk) begin
    if (rst_ni) begin
      if (beat_valid && beat_gnt)
        gnt_cnt <= gnt_cnt + 1;

      if (beat_rvalid)
        rvalid_cnt <= rvalid_cnt + 1;
    end
  end

  logic [DataWidth-1:0] wsent [0:31];
  int wsent_n;

  logic [DataWidth-1:0] rrecv [0:31];
  int rrecv_n;

  always @(posedge clk) begin
    if (rst_ni) begin
      if (burst_req.wvalid && burst_rsp.wready) begin
        wsent[wsent_n] <= burst_req.wdata;
        wsent_n <= wsent_n + 1;
      end

      if (beat_rvalid) begin
        rrecv[rrecv_n] <= beat_rdata;
        rrecv_n <= rrecv_n + 1;
      end
    end
  end

  burst_hdr_t hdr_seen;

  always @(posedge clk) begin
    if (rst_ni && burst_req.hdr_valid && burst_rsp.hdr_gnt) begin
      hdr_seen <= burst_req.hdr;
    end
  end

  // ══════════════════════════════════════════════════════════════════
  // iDMA-MODELL
  // ══════════════════════════════════════════════════════════════════

  task automatic idma_write(input [31:0] start, input [7:0] blen);
    for (int k = 0; k <= blen; k++) begin
      @(negedge clk);

      beat_valid  = 1'b1;
      beat_we     = 1'b1;
      beat_addr   = start + (k << 2);
      beat_wdata  = WDATA_BASE + (start + (k << 2));
      beat_bfirst = (k == 0);
      beat_blast  = (k == blen);
      beat_blen   = blen;

      do @(posedge clk); while (!beat_gnt);
    end

    @(negedge clk);

    beat_valid  = 1'b0;
    beat_we     = 1'b0;
    beat_bfirst = 1'b0;
    beat_blast  = 1'b0;
    beat_addr   = '0;
    beat_wdata  = '0;
    beat_blen   = '0;
  endtask

  task automatic idma_read(input [31:0] start, input [7:0] blen);
    for (int k = 0; k <= blen; k++) begin
      @(negedge clk);

      beat_valid  = 1'b1;
      beat_we     = 1'b0;
      beat_addr   = start + (k << 2);
      beat_wdata  = '0;
      beat_bfirst = (k == 0);
      beat_blast  = (k == blen);
      beat_blen   = blen;

      do @(posedge clk); while (!beat_gnt);
    end

    @(negedge clk);

    beat_valid  = 1'b0;
    beat_we     = 1'b0;
    beat_bfirst = 1'b0;
    beat_blast  = 1'b0;
    beat_addr   = '0;
    beat_wdata  = '0;
    beat_blen   = '0;
  endtask

  task automatic chk(input logic cond, input string msg);
    if (!cond) begin
      $error("[C] FAIL: %s", msg);
      errors++;
    end
  endtask

  // ══════════════════════════════════════════════════════════════════
  // STIMULUS
  // ══════════════════════════════════════════════════════════════════

  int gbase, rbase, wbase, rcbase;

  initial begin
    errors = 0;
    rst_ni = 0;

    beat_valid  = 0;
    beat_we     = 0;
    beat_addr   = 0;
    beat_wdata  = 0;
    beat_bfirst = 0;
    beat_blast  = 0;
    beat_blen   = 0;

    gnt_cnt    = 0;
    rvalid_cnt = 0;
    wsent_n    = 0;
    rrecv_n    = 0;
    hdr_seen   = '0;

    repeat (3) @(posedge clk);
    rst_ni = 1;

    @(posedge clk);
    #1;

    // Test 1: WRITE-Burst, 4 Woerter
    $display("[C] Test 1: write-burst blen=3");

    gbase = gnt_cnt;
    rbase = rvalid_cnt;
    wbase = wsent_n;

    idma_write(32'h100, 8'd3);

    repeat (6) @(posedge clk);

    chk(hdr_seen.start_addr == 32'h100 &&
        hdr_seen.blen       == 3 &&
        hdr_seen.we         == 1,
        "T1 Header");

    chk(wsent_n - wbase == 4, "T1 #wdata==4");

    for (int k = 0; k < 4; k++) begin
      chk(wsent[wbase+k] == WDATA_BASE + (32'h100 + (k << 2)),
          $sformatf("T1 wdata%0d", k));
    end

    chk(gnt_cnt - gbase    == 4, "T1 #gnt==4");
    chk(rvalid_cnt - rbase == 4, "T1 #rvalid==4");

    // Test 2: READ-Burst, 4 Woerter
    $display("[C] Test 2: read-burst blen=3");

    gbase  = gnt_cnt;
    rbase  = rvalid_cnt;
    rcbase = rrecv_n;

    idma_read(32'h200, 8'd3);

    repeat (12) @(posedge clk);

    chk(hdr_seen.start_addr == 32'h200 &&
        hdr_seen.blen       == 3 &&
        hdr_seen.we         == 0,
        "T2 Header");

    chk(rrecv_n - rcbase == 4, "T2 #rdata==4");

    for (int k = 0; k < 4; k++) begin
      chk(rrecv[rcbase+k] == RDATA_BASE + (32'h200 + (k << 2)),
          $sformatf("T2 rdata%0d", k));
    end

    chk(gnt_cnt - gbase    == 4, "T2 #gnt==4");
    chk(rvalid_cnt - rbase == 4, "T2 #rvalid==4");

    // Test 3: Single-Beat WRITE
    $display("[C] Test 3: single-beat write");

    gbase = gnt_cnt;
    rbase = rvalid_cnt;
    wbase = wsent_n;

    idma_write(32'h300, 8'd0);

    repeat (6) @(posedge clk);

    chk(wsent_n - wbase == 1 &&
        wsent[wbase] == WDATA_BASE + 32'h300,
        "T3 wdata");

    chk(gnt_cnt - gbase == 1 &&
        rvalid_cnt - rbase == 1,
        "T3 #gnt==#rvalid==1");

    // Test 4: Single-Beat READ
    $display("[C] Test 4: single-beat read");

    gbase  = gnt_cnt;
    rbase  = rvalid_cnt;
    rcbase = rrecv_n;

    idma_read(32'h400, 8'd0);

    repeat (8) @(posedge clk);

    chk(rrecv_n - rcbase == 1 &&
        rrecv[rcbase] == RDATA_BASE + 32'h400,
        "T4 rdata");

    chk(gnt_cnt - gbase == 1 &&
        rvalid_cnt - rbase == 1,
        "T4 #gnt==#rvalid==1");

    // Test 5: zwei Write-Bursts back-to-back
    $display("[C] Test 5: back-to-back write-bursts");

    gbase = gnt_cnt;
    rbase = rvalid_cnt;

    idma_write(32'h500, 8'd1);
    idma_write(32'h600, 8'd1);

    repeat (8) @(posedge clk);

    chk(gnt_cnt - gbase == 4 &&
        rvalid_cnt - rbase == 4,
        "T5 2x2 Woerter, #gnt==#rvalid==4");

    if (errors == 0)
      $display("[C] ============ COMPRESSOR TB PASSED ============");
    else
      $display("[C] ============ %0d ERROR(S) ============", errors);

    $finish;
  end

  // Watchdog
  initial begin
    #50000;

    $display("[C] !!! STUCK @ %0t", $time);
    $display("    Compressor: state_q=%0d count_q=%0d",
             i_dut.state_q, i_dut.count_q);

    $display("    fake-EP   : fe_q=%0d fe_blen_q=%0d fe_addr_q=%08x",
             fe_q, fe_blen_q, fe_addr_q);

    $display("    beats     : valid=%b gnt=%b we=%b bfirst=%b blast=%b blen=%0d first_dbg=%b",
             beat_valid, beat_gnt, beat_we, beat_bfirst, beat_blast, beat_blen,
             first_beat_dbg);

    $display("    burst_req : hdr_valid=%b wvalid=%b wdata=%08x rready=%b",
             burst_req.hdr_valid, burst_req.wvalid, burst_req.wdata, burst_req.rready);

    $display("    burst_rsp : hdr_gnt=%b wready=%b rvalid=%b rdata=%08x",
             burst_rsp.hdr_gnt, burst_rsp.wready, burst_rsp.rvalid, burst_rsp.rdata);

    $display("    rsp_comb  : hdr_gnt=%b wready=%b rvalid=%b rdata=%08x",
             burst_rsp_comb.hdr_gnt, burst_rsp_comb.wready,
             burst_rsp_comb.rvalid, burst_rsp_comb.rdata);

    $finish;
  end

  initial begin
    $dumpfile("tb_burst_compressor.vcd");
    $dumpvars(0, tb_burst_compressor);
  end

endmodule