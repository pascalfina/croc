// ════════════════════════════════════════════════════════════════════════
// TB 2: END-TO-END iDMA -> Compressor -> Endpoint -> SRAM (+ CPU)
// ════════════════════════════════════════════════════════════════════════
`timescale 1ns/1ps

module tb_burst_e2e import burst_pkg::*; ();

  logic clk, rst_ni;
  int   errors;

  localparam logic [1:0]  EP_IDLE          = 2'd0;
  localparam logic [1:0]  COMP_READ_STREAM = 2'd2;   // Compressor-State READ_STREAM
  localparam logic [31:0] WDATA_BASE       = 32'hAA00_0000;

  // iDMA-Beats
  logic                     beat_valid, beat_we, beat_bfirst, beat_blast;
  logic [AddrWidth-1:0]     beat_addr;
  logic [DataWidth-1:0]     beat_wdata;
  logic [BurstLenWidth-1:0] beat_blen;
  logic                     beat_gnt;
  logic [DataWidth-1:0]     beat_rdata;
  logic                     beat_rvalid;

  // Compressor <-> Endpoint
  burst_req_t c2e_req;

  burst_rsp_t e2c_rsp;
  burst_rsp_t e2c_rsp_raw;

  // Wichtig: bricht Zero-Time-Loop Endpoint -> Compressor
  assign #1 e2c_rsp = e2c_rsp_raw;

  // Endpoint <-> SRAM
  logic                   sram_req, sram_we;
  logic [AddrWidth-1:0]   sram_addr;
  logic [DataWidth-1:0]   sram_wdata, sram_rdata;
  logic [DataWidth/8-1:0] sram_be;
  logic                   sram_gnt;
  logic [DataWidth-1:0]   mem [0:1023];

  // CPU -> Endpoint
  logic                   cpu_req, cpu_we;
  logic [AddrWidth-1:0]   cpu_addr;
  logic [DataWidth-1:0]   cpu_wdata, cpu_rdata;
  logic [DataWidth/8-1:0] cpu_be;
  logic                   cpu_gnt, cpu_rvalid;

  // DUTs
  burst_compressor i_comp (
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

    .burst_req_o(c2e_req),
    .burst_rsp_i(e2c_rsp)
  );

  burst_endpoint i_ep (
    .clk_i(clk),
    .rst_ni(rst_ni),

    .burst_req_i(c2e_req),
    .burst_rsp_o(e2c_rsp_raw),

    .sram_req_o(sram_req),
    .sram_we_o(sram_we),
    .sram_addr_o(sram_addr),
    .sram_wdata_o(sram_wdata),
    .sram_be_o(sram_be),
    .sram_gnt_i(sram_gnt),
    .sram_rdata_i(sram_rdata),

    .cpu_req_i(cpu_req),
    .cpu_we_i(cpu_we),
    .cpu_addr_i(cpu_addr),
    .cpu_wdata_i(cpu_wdata),
    .cpu_be_i(cpu_be),
    .cpu_gnt_o(cpu_gnt),
    .cpu_rdata_o(cpu_rdata),
    .cpu_rvalid_o(cpu_rvalid)
  );

  initial clk = 0;
  always #5 clk = ~clk;

  // Fake SRAM: single-port, gnt=1, read latency=1
  assign sram_gnt = 1'b1;

  always_ff @(posedge clk) begin
    if (sram_req && sram_we) begin
      mem[sram_addr >> 2] <= sram_wdata;
    end

    if (sram_req && !sram_we) begin
      sram_rdata <= mem[sram_addr >> 2];
    end
  end

  // Monitore
  int gnt_cnt, rvalid_cnt;

  always @(posedge clk) begin
    if (rst_ni) begin
      if (beat_valid && beat_gnt)
        gnt_cnt <= gnt_cnt + 1;

      if (beat_rvalid)
        rvalid_cnt <= rvalid_cnt + 1;
    end
  end

  logic [DataWidth-1:0] rrecv [0:31];
  int rrecv_n;

  // nur READ-Daten sammeln: beat_rvalid pulst AUCH bei Write-Quittungen
  // (rvalid = Response, nicht nur Read) -> ueber Compressor-State filtern
  always @(posedge clk) begin
    if (rst_ni && beat_rvalid && i_comp.state_q == COMP_READ_STREAM) begin
      rrecv[rrecv_n] <= beat_rdata;
      rrecv_n <= rrecv_n + 1;
    end
  end

  // LOCK-Monitor
  always @(posedge clk) begin
    if (rst_ni && (i_ep.state_q !== EP_IDLE) && cpu_gnt) begin
      $error("[E2E] LOCK VERLETZT @ %0t: cpu_gnt waehrend Burst state=%0d",
             $time, i_ep.state_q);
      errors++;
    end
  end

  // SRAM write byte-enable check
  always @(posedge clk) begin
    if (rst_ni && sram_req && sram_we && sram_be !== 4'b1111) begin
      $error("[E2E] SRAM-Write mit be=%b erwartet 1111 @ %0t",
             sram_be, $time);
      errors++;
    end
  end

  // iDMA write model
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
    beat_addr   = '0;
    beat_wdata  = '0;
    beat_bfirst = 1'b0;
    beat_blast  = 1'b0;
    beat_blen   = '0;
  endtask

  // iDMA read model
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
    beat_addr   = '0;
    beat_wdata  = '0;
    beat_bfirst = 1'b0;
    beat_blast  = 1'b0;
    beat_blen   = '0;
  endtask

  // CPU write model
  task automatic cpu_write(input [31:0] addr, input [31:0] data);
    @(negedge clk);

    cpu_req   = 1'b1;
    cpu_we    = 1'b1;
    cpu_addr  = addr;
    cpu_wdata = data;
    cpu_be    = '1;

    do @(posedge clk); while (!cpu_gnt);

    @(negedge clk);

    cpu_req   = 1'b0;
    cpu_we    = 1'b0;
    cpu_addr  = '0;
    cpu_wdata = '0;
    cpu_be    = '0;
  endtask

  // CPU read model
  task automatic cpu_read(input [31:0] addr, output [31:0] data);
    @(negedge clk);

    cpu_req   = 1'b1;
    cpu_we    = 1'b0;
    cpu_addr  = addr;
    cpu_wdata = '0;
    cpu_be    = '1;

    do @(posedge clk); while (!cpu_gnt);   // T: Read angenommen
    #1;                                     // in (T,T+1): rvalid + rdata gueltig

    if (!cpu_rvalid) begin
      $error("[E2E] cpu_read @ %08x: rvalid fehlt", addr);
      errors++;
    end

    data = cpu_rdata;

    @(negedge clk);
    cpu_req  = 1'b0;
    cpu_addr = '0;
    cpu_be   = '0;
  endtask

  task automatic chk(input logic cond, input string msg);
    if (!cond) begin
      $error("[E2E] FAIL: %s", msg);
      errors++;
    end
  endtask

  // Stimulus
  int gbase, rbase, rcbase;
  logic [31:0] rd;

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

    cpu_req   = 0;
    cpu_we    = 0;
    cpu_addr  = 0;
    cpu_wdata = 0;
    cpu_be    = 0;

    gnt_cnt    = 0;
    rvalid_cnt = 0;
    rrecv_n    = 0;
    sram_rdata = 0;

    for (int i = 0; i < 1024; i++) begin
      mem[i] = 32'hDEAD_BEEF;
    end

    repeat (3) @(posedge clk);
    rst_ni = 1;

    @(posedge clk);
    #1;

    // Test 1
    $display("[E2E] Test 1: write-burst 0x100, 4 Woerter");

    gbase = gnt_cnt;
    rbase = rvalid_cnt;

    idma_write(32'h100, 8'd3);

    repeat (6) @(posedge clk);

    for (int k = 0; k < 4; k++) begin
      chk(mem[(32'h100 + (k << 2)) >> 2] == WDATA_BASE + (32'h100 + (k << 2)),
          $sformatf("T1 SRAM[%0d]", k));
    end

    chk(gnt_cnt - gbase == 4 &&
        rvalid_cnt - rbase == 4,
        "T1 #gnt==#rvalid==4");

    // Test 2
    $display("[E2E] Test 2: read-burst 0x100, 4 Woerter");

    gbase  = gnt_cnt;
    rbase  = rvalid_cnt;
    rcbase = rrecv_n;

    idma_read(32'h100, 8'd3);

    repeat (12) @(posedge clk);

    chk(rrecv_n - rcbase == 4, "T2 #rdata==4");

    for (int k = 0; k < 4; k++) begin
      chk(rrecv[rcbase + k] == WDATA_BASE + (32'h100 + (k << 2)),
          $sformatf("T2 rdata[%0d]", k));
    end

    chk(gnt_cnt - gbase == 4 &&
        rvalid_cnt - rbase == 4,
        "T2 #gnt==#rvalid==4");

    // Test 3
    $display("[E2E] Test 3: CPU write/read");

    cpu_write(32'h280, 32'h1234_5678);

    repeat (2) @(posedge clk);

    chk(mem[32'h280 >> 2] == 32'h1234_5678,
        "T3 CPU-write in SRAM");

    cpu_read(32'h280, rd);

    chk(rd == 32'h1234_5678, "T3 CPU-read");

    // Test 4
    $display("[E2E] Test 4: contention burst + CPU, lock check");

    gbase = gnt_cnt;
    rbase = rvalid_cnt;

    fork
      idma_write(32'h180, 8'd3);
      cpu_write(32'h700, 32'hCAFE_BABE);
    join

    repeat (6) @(posedge clk);

    for (int k = 0; k < 4; k++) begin
      chk(mem[(32'h180 + (k << 2)) >> 2] == WDATA_BASE + (32'h180 + (k << 2)),
          $sformatf("T4 burst[%0d]", k));
    end

    chk(mem[32'h700 >> 2] == 32'hCAFE_BABE,
        "T4 CPU kam nach Burst durch");

    chk(gnt_cnt - gbase == 4 &&
        rvalid_cnt - rbase == 4,
        "T4 #gnt==#rvalid==4");

    // Test 5
    $display("[E2E] Test 5: single-beat write+read");

    gbase  = gnt_cnt;
    rbase  = rvalid_cnt;
    rcbase = rrecv_n;

    idma_write(32'h500, 8'd0);

    repeat (6) @(posedge clk);

    chk(mem[32'h500 >> 2] == WDATA_BASE + 32'h500,
        "T5 SRAM single");

    idma_read(32'h500, 8'd0);

    repeat (8) @(posedge clk);

    chk(rrecv[rcbase] == WDATA_BASE + 32'h500,
        "T5 read single");

    chk(gnt_cnt - gbase == 2 &&
        rvalid_cnt - rbase == 2,
        "T5 1 write + 1 read #gnt==#rvalid==2");

    if (errors == 0) begin
      $display("[E2E] ============ END-TO-END TB PASSED ============");
    end else begin
      $display("[E2E] ============ %0d ERROR(S) ============", errors);
    end

    $finish;
  end

  // Watchdog
  initial begin
    #50000;

    $display("[E2E] !!! STUCK @ %0t", $time);

    $display("  COMP: state_q=%0d count_q=%0d",
             i_comp.state_q, i_comp.count_q);

    $display("  EP  : state_q=%0d addr_q=%08x blen_q=%0d rvalid_q=%b",
             i_ep.state_q, i_ep.addr_q, i_ep.blen_q, i_ep.rvalid_q);

    $display("  beat: valid=%b gnt=%b we=%b bfirst=%b blast=%b addr=%08x wdata=%08x blen=%0d",
             beat_valid, beat_gnt, beat_we, beat_bfirst, beat_blast,
             beat_addr, beat_wdata, beat_blen);

    $display("  req : hdr_valid=%b hdr_we=%b hdr_addr=%08x hdr_blen=%0d wvalid=%b wdata=%08x rready=%b",
             c2e_req.hdr_valid, c2e_req.hdr.we, c2e_req.hdr.start_addr,
             c2e_req.hdr.blen, c2e_req.wvalid, c2e_req.wdata, c2e_req.rready);

    $display("  rsp : hdr_gnt=%b wready=%b rvalid=%b rdata=%08x",
             e2c_rsp.hdr_gnt, e2c_rsp.wready, e2c_rsp.rvalid, e2c_rsp.rdata);

    $display("  raw : hdr_gnt=%b wready=%b rvalid=%b rdata=%08x",
             e2c_rsp_raw.hdr_gnt, e2c_rsp_raw.wready,
             e2c_rsp_raw.rvalid, e2c_rsp_raw.rdata);

    $display("  sram: req=%b we=%b gnt=%b addr=%08x wdata=%08x rdata=%08x be=%b",
             sram_req, sram_we, sram_gnt, sram_addr,
             sram_wdata, sram_rdata, sram_be);

    $display("  cpu : req=%b gnt=%b we=%b rvalid=%b addr=%08x wdata=%08x rdata=%08x",
             cpu_req, cpu_gnt, cpu_we, cpu_rvalid,
             cpu_addr, cpu_wdata, cpu_rdata);

    $finish;
  end

  initial begin
    $dumpfile("tb_burst_e2e.vcd");
    $dumpvars(0, tb_burst_e2e);
  end

endmodule