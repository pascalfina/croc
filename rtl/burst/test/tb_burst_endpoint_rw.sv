// End-to-end testbench for burst_endpoint_rw:
// read-compressor + write-compressor + single-port SRAM + CPU contention.
`timescale 1ns/1ps

module tb_burst_endpoint_rw import burst_pkg::*; ();

  localparam logic [1:0] R_IDLE_VAL = 2'd0;
  localparam logic [1:0] W_IDLE_VAL = 2'd0;

  localparam logic [31:0] RDATA_BASE = 32'hC0DE_0000;
  localparam logic [31:0] WDATA_BASE = 32'hAA00_0000;

  logic clk, rst_ni;
  int   errors;
  int   cyc;

  // Read iDMA beat side.
  logic                     rd_beat_valid;
  logic                     rd_beat_we;
  logic                     rd_beat_bfirst;
  logic                     rd_beat_blast;
  logic [AddrWidth-1:0]     rd_beat_addr;
  logic [DataWidth-1:0]     rd_beat_wdata;
  logic [BurstLenWidth-1:0] rd_beat_blen;
  logic                     rd_beat_gnt;
  logic [DataWidth-1:0]     rd_beat_rdata;
  logic                     rd_beat_rvalid;

  // Write iDMA beat side.
  logic                     wr_beat_valid;
  logic                     wr_beat_we;
  logic                     wr_beat_bfirst;
  logic                     wr_beat_blast;
  logic [AddrWidth-1:0]     wr_beat_addr;
  logic [DataWidth-1:0]     wr_beat_wdata;
  logic [BurstLenWidth-1:0] wr_beat_blen;
  logic                     wr_beat_gnt;
  logic [DataWidth-1:0]     wr_beat_rdata;
  logic                     wr_beat_rvalid;

  // Compressor <-> endpoint.
  burst_req_t rd_req;
  burst_req_t wr_req;
  burst_rsp_t rd_rsp_raw;
  burst_rsp_t wr_rsp_raw;
  burst_rsp_t rd_rsp_to_comp;
  burst_rsp_t wr_rsp_to_comp;

  // Break zero-time response loops, same as the existing compressor/e2e TBs.
  assign #1 rd_rsp_to_comp = rd_rsp_raw;
  assign #1 wr_rsp_to_comp = wr_rsp_raw;

  // Endpoint <-> SRAM.
  logic                   sram_req;
  logic                   sram_we;
  logic [AddrWidth-1:0]   sram_addr;
  logic [DataWidth-1:0]   sram_wdata;
  logic [DataWidth/8-1:0] sram_be;
  logic                   sram_gnt;
  logic [DataWidth-1:0]   sram_rdata;

  // CPU side.
  logic                   cpu_req;
  logic                   cpu_we;
  logic [AddrWidth-1:0]   cpu_addr;
  logic [DataWidth-1:0]   cpu_wdata;
  logic [DataWidth/8-1:0] cpu_be;
  logic                   cpu_gnt;
  logic                   cpu_rvalid;
  logic [DataWidth-1:0]   cpu_rdata;

  // Memory and scoreboard state.
  logic [DataWidth-1:0] mem [0:2047];

  logic [DataWidth-1:0] rd_recv [0:127];
  int rd_recv_n;

  int wr_ack_n;
  int rd_sram_n;
  int wr_sram_n;
  int cpu_sram_n;
  int header_race_n;
  int lock_violation_n;

  bit  record_rw_seq;
  byte rw_seq [0:255];
  int  rw_seq_n;

  bit stall_mode;

  // DUTs.
  burst_compressor i_rd_comp (
    .clk_i          ( clk              ),
    .rst_ni         ( rst_ni           ),
    .beat_valid_i   ( rd_beat_valid    ),
    .beat_gnt_o     ( rd_beat_gnt      ),
    .beat_addr_i    ( rd_beat_addr     ),
    .beat_wdata_i   ( rd_beat_wdata    ),
    .beat_we_i      ( rd_beat_we       ),
    .beat_bfirst_i  ( rd_beat_bfirst   ),
    .beat_blast_i   ( rd_beat_blast    ),
    .beat_blen_i    ( rd_beat_blen     ),
    .beat_rdata_o   ( rd_beat_rdata    ),
    .beat_rvalid_o  ( rd_beat_rvalid   ),
    .burst_req_o    ( rd_req           ),
    .burst_rsp_i    ( rd_rsp_to_comp   )
  );

  burst_compressor i_wr_comp (
    .clk_i          ( clk              ),
    .rst_ni         ( rst_ni           ),
    .beat_valid_i   ( wr_beat_valid    ),
    .beat_gnt_o     ( wr_beat_gnt      ),
    .beat_addr_i    ( wr_beat_addr     ),
    .beat_wdata_i   ( wr_beat_wdata    ),
    .beat_we_i      ( wr_beat_we       ),
    .beat_bfirst_i  ( wr_beat_bfirst   ),
    .beat_blast_i   ( wr_beat_blast    ),
    .beat_blen_i    ( wr_beat_blen     ),
    .beat_rdata_o   ( wr_beat_rdata    ),
    .beat_rvalid_o  ( wr_beat_rvalid   ),
    .burst_req_o    ( wr_req           ),
    .burst_rsp_i    ( wr_rsp_to_comp   )
  );

  burst_endpoint_rw i_ep (
    .clk_i        ( clk        ),
    .rst_ni       ( rst_ni     ),

    .rd_req_i     ( rd_req     ),
    .rd_rsp_o     ( rd_rsp_raw ),
    .wr_req_i     ( wr_req     ),
    .wr_rsp_o     ( wr_rsp_raw ),

    .cpu_req_i    ( cpu_req    ),
    .cpu_we_i     ( cpu_we     ),
    .cpu_addr_i   ( cpu_addr   ),
    .cpu_wdata_i  ( cpu_wdata  ),
    .cpu_be_i     ( cpu_be     ),
    .cpu_gnt_o    ( cpu_gnt    ),
    .cpu_rvalid_o ( cpu_rvalid ),
    .cpu_rdata_o  ( cpu_rdata  ),

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

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni)
      cyc <= 0;
    else
      cyc <= cyc + 1;
  end

  // Deterministic SRAM stalls. The memory only accepts transfers when gnt is high.
  always @(*) begin
    if (!rst_ni) begin
      sram_gnt = 1'b0;
    end else if (!stall_mode) begin
      sram_gnt = 1'b1;
    end else begin
      sram_gnt = (cyc[2:0] != 3'd1) && (cyc[2:0] != 3'd5);
    end
  end

  function automatic int unsigned word_idx(input logic [AddrWidth-1:0] addr);
    word_idx = addr[12:2];
  endfunction

  function automatic logic [31:0] apply_be(
    input logic [31:0] old_word,
    input logic [31:0] new_word,
    input logic [3:0]  be
  );
    logic [31:0] result;
    result = old_word;
    for (int b = 0; b < 4; b++) begin
      if (be[b])
        result[b*8 +: 8] = new_word[b*8 +: 8];
    end
    return result;
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      sram_rdata <= '0;
    end else if (sram_req && sram_gnt) begin
      if (sram_we) begin
        mem[word_idx(sram_addr)] <= apply_be(mem[word_idx(sram_addr)], sram_wdata, sram_be);
      end else begin
        sram_rdata <= mem[word_idx(sram_addr)];
      end
    end
  end

  // Scoreboard and protocol monitors.
  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_recv_n        <= 0;
      wr_ack_n         <= 0;
      rd_sram_n        <= 0;
      wr_sram_n        <= 0;
      cpu_sram_n       <= 0;
      header_race_n    <= 0;
      lock_violation_n <= 0;
      rw_seq_n         <= 0;
    end else begin
      if (rd_beat_rvalid) begin
        rd_recv[rd_recv_n] <= rd_beat_rdata;
        rd_recv_n          <= rd_recv_n + 1;
      end

      if (wr_beat_rvalid)
        wr_ack_n <= wr_ack_n + 1;

      if (cpu_req && i_ep.burst_starting)
        header_race_n <= header_race_n + 1;

      if (cpu_gnt &&
          ((i_ep.r_state_q !== R_IDLE_VAL) ||
           (i_ep.w_state_q !== W_IDLE_VAL) ||
           i_ep.burst_starting)) begin
        $error("[RW] LOCK violation @ %0t: cpu_gnt while DMA active/starting", $time);
        lock_violation_n <= lock_violation_n + 1;
        errors++;
      end

      if (sram_req && sram_gnt) begin
        if (({1'b0, i_ep.rd_grant} +
             {1'b0, i_ep.wr_grant} +
             {1'b0, i_ep.cpu_grant}) !== 2'd1) begin
          $error("[RW] SRAM source is not one-hot @ %0t rd=%b wr=%b cpu=%b",
                 $time, i_ep.rd_grant, i_ep.wr_grant, i_ep.cpu_grant);
          errors++;
        end

        if (i_ep.rd_grant) begin
          rd_sram_n <= rd_sram_n + 1;
          if (sram_we) begin
            $error("[RW] Read grant drove SRAM write @ %0t", $time);
            errors++;
          end
          if (record_rw_seq) begin
            rw_seq[rw_seq_n] <= "R";
            rw_seq_n         <= rw_seq_n + 1;
          end
        end

        if (i_ep.wr_grant) begin
          wr_sram_n <= wr_sram_n + 1;
          if (!sram_we) begin
            $error("[RW] Write grant drove SRAM read @ %0t", $time);
            errors++;
          end
          if (sram_be !== '1) begin
            $error("[RW] DMA write be=%b expected all ones @ %0t", sram_be, $time);
            errors++;
          end
          if (record_rw_seq) begin
            rw_seq[rw_seq_n] <= "W";
            rw_seq_n         <= rw_seq_n + 1;
          end
        end

        if (i_ep.cpu_grant)
          cpu_sram_n <= cpu_sram_n + 1;
      end
    end
  end

  task automatic chk(input logic cond, input string msg);
    if (!cond) begin
      $error("[RW] FAIL: %s", msg);
      errors++;
    end
  endtask

  task automatic wait_cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic wait_until_rd_recv(input string name, input int target);
    int guard;
    guard = 0;
    while (rd_recv_n < target && guard < 500) begin
      @(posedge clk);
      guard++;
    end
    #1;
    if (rd_recv_n < target) begin
      $error("[RW] Timeout waiting for %s: got %0d expected %0d", name, rd_recv_n, target);
      errors++;
    end
  endtask

  task automatic wait_until_wr_ack(input string name, input int target);
    int guard;
    guard = 0;
    while (wr_ack_n < target && guard < 500) begin
      @(posedge clk);
      guard++;
    end
    #1;
    if (wr_ack_n < target) begin
      $error("[RW] Timeout waiting for %s: got %0d expected %0d", name, wr_ack_n, target);
      errors++;
    end
  endtask

  task automatic clear_read_beats;
    rd_beat_valid  = 1'b0;
    rd_beat_we     = 1'b0;
    rd_beat_addr   = '0;
    rd_beat_wdata  = '0;
    rd_beat_bfirst = 1'b0;
    rd_beat_blast  = 1'b0;
    rd_beat_blen   = '0;
  endtask

  task automatic clear_write_beats;
    wr_beat_valid  = 1'b0;
    wr_beat_we     = 1'b0;
    wr_beat_addr   = '0;
    wr_beat_wdata  = '0;
    wr_beat_bfirst = 1'b0;
    wr_beat_blast  = 1'b0;
    wr_beat_blen   = '0;
  endtask

  task automatic idma_read(input logic [31:0] start, input logic [7:0] blen);
    int done_target;

    done_target = rd_recv_n + blen + 1;

    for (int k = 0; k <= blen; k++) begin
      @(negedge clk);
      rd_beat_valid  = 1'b1;
      rd_beat_we     = 1'b0;
      rd_beat_addr   = start + (k << 2);
      rd_beat_wdata  = '0;
      rd_beat_bfirst = (k == 0);
      rd_beat_blast  = (k == blen);
      rd_beat_blen   = blen;

      do @(posedge clk); while (!rd_beat_gnt);
    end

    @(negedge clk);
    clear_read_beats();
    wait_until_rd_recv("idma_read completion", done_target);
  endtask

  task automatic idma_write(
    input logic [31:0] start,
    input logic [7:0]  blen,
    input logic [31:0] data_base
  );
    for (int k = 0; k <= blen; k++) begin
      @(negedge clk);
      wr_beat_valid  = 1'b1;
      wr_beat_we     = 1'b1;
      wr_beat_addr   = start + (k << 2);
      wr_beat_wdata  = data_base + start + (k << 2);
      wr_beat_bfirst = (k == 0);
      wr_beat_blast  = (k == blen);
      wr_beat_blen   = blen;

      do @(posedge clk); while (!wr_beat_gnt);
    end

    @(negedge clk);
    clear_write_beats();
  endtask

  task automatic cpu_write(input logic [31:0] addr, input logic [31:0] data);
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

  task automatic cpu_read(input logic [31:0] addr, output logic [31:0] data);
    @(negedge clk);
    cpu_req   = 1'b1;
    cpu_we    = 1'b0;
    cpu_addr  = addr;
    cpu_wdata = '0;
    cpu_be    = '1;

    do @(posedge clk); while (!cpu_gnt);
    #1;

    if (!cpu_rvalid) begin
      $error("[RW] cpu_read @ %08x missing rvalid", addr);
      errors++;
    end
    data = cpu_rdata;

    @(negedge clk);
    cpu_req  = 1'b0;
    cpu_addr = '0;
    cpu_be   = '0;
  endtask

  task automatic preload_read_region(input logic [31:0] start, input int beats);
    for (int k = 0; k < beats; k++)
      mem[word_idx(start + (k << 2))] = RDATA_BASE + start + (k << 2);
  endtask

  task automatic check_read_data(
    input int          base_idx,
    input logic [31:0] start,
    input int          beats,
    input string       tag
  );
    for (int k = 0; k < beats; k++) begin
      chk(rd_recv[base_idx + k] == RDATA_BASE + start + (k << 2),
          $sformatf("%s read data[%0d]", tag, k));
    end
  endtask

  task automatic check_write_mem(
    input logic [31:0] start,
    input int          beats,
    input logic [31:0] data_base,
    input string       tag
  );
    for (int k = 0; k < beats; k++) begin
      chk(mem[word_idx(start + (k << 2))] == data_base + start + (k << 2),
          $sformatf("%s write mem[%0d]", tag, k));
    end
  endtask

  task automatic check_alternating_sequence(input int expected_len, input string tag);
    chk(rw_seq_n == expected_len,
        $sformatf("%s sequence length got %0d expected %0d", tag, rw_seq_n, expected_len));

    for (int k = 1; k < rw_seq_n; k++) begin
      chk(rw_seq[k] != rw_seq[k-1],
          $sformatf("%s not alternating at entry %0d: %c/%c",
                    tag, k, rw_seq[k-1], rw_seq[k]));
    end
  endtask

  logic [31:0] cpu_rd;
  int          base_rd_recv;
  int          base_wr_ack;
  int          base_rd_sram;
  int          base_wr_sram;
  int          base_cpu_sram;
  int          base_header_race;

  initial begin
    errors        = 0;
    rst_ni        = 1'b0;
    stall_mode    = 1'b0;
    record_rw_seq = 1'b0;

    clear_read_beats();
    clear_write_beats();

    cpu_req   = 1'b0;
    cpu_we    = 1'b0;
    cpu_addr  = '0;
    cpu_wdata = '0;
    cpu_be    = '0;

    for (int i = 0; i < 2048; i++)
      mem[i] = 32'hDEAD_BEEF;

    repeat (4) @(posedge clk);
    rst_ni = 1'b1;
    wait_cycles(1);

    $display("[RW] Test 1: CPU idle write/read");
    cpu_write(32'h0000_0300, 32'h1234_5678);
    wait_cycles(2);
    chk(mem[word_idx(32'h0000_0300)] == 32'h1234_5678, "T1 CPU write reached SRAM");
    cpu_read(32'h0000_0300, cpu_rd);
    chk(cpu_rd == 32'h1234_5678, "T1 CPU read data");

    $display("[RW] Test 2: isolated write-compressor -> endpoint_rw -> SRAM");
    base_wr_ack  = wr_ack_n;
    base_wr_sram = wr_sram_n;
    idma_write(32'h0000_0100, 8'd3, WDATA_BASE);
    wait_until_wr_ack("T2 write acks", base_wr_ack + 4);
    wait_cycles(3);
    check_write_mem(32'h0000_0100, 4, WDATA_BASE, "T2");
    chk(wr_sram_n - base_wr_sram == 4, "T2 accepted four SRAM writes");

    $display("[RW] Test 3: isolated read-compressor -> endpoint_rw -> SRAM");
    preload_read_region(32'h0000_0200, 4);
    base_rd_recv = rd_recv_n;
    base_rd_sram = rd_sram_n;
    idma_read(32'h0000_0200, 8'd3);
    wait_until_rd_recv("T3 read data", base_rd_recv + 4);
    check_read_data(base_rd_recv, 32'h0000_0200, 4, "T3");
    chk(rd_sram_n - base_rd_sram == 4, "T3 accepted four SRAM reads");

    $display("[RW] Test 4: simultaneous read/write same SRAM bank + CPU contention + stalls");
    preload_read_region(32'h0000_0400, 8);

    base_rd_recv     = rd_recv_n;
    base_wr_ack      = wr_ack_n;
    base_rd_sram     = rd_sram_n;
    base_wr_sram     = wr_sram_n;
    base_cpu_sram    = cpu_sram_n;
    base_header_race = header_race_n;
    rw_seq_n         = 0;
    record_rw_seq    = 1'b1;
    stall_mode       = 1'b1;

    fork
      idma_read (32'h0000_0400, 8'd7);
      idma_write(32'h0000_0440, 8'd7, 32'hBB00_0000);
      cpu_write (32'h0000_0500, 32'hCAFE_BABE);
    join

    wait_until_rd_recv("T4 read data", base_rd_recv + 8);
    wait_until_wr_ack("T4 write acks", base_wr_ack + 8);
    wait_cycles(4);

    record_rw_seq = 1'b0;
    stall_mode    = 1'b0;

    check_read_data(base_rd_recv, 32'h0000_0400, 8, "T4");
    check_write_mem(32'h0000_0440, 8, 32'hBB00_0000, "T4");
    chk(mem[word_idx(32'h0000_0500)] == 32'hCAFE_BABE, "T4 CPU write passed after DMA");
    chk(rd_sram_n  - base_rd_sram  == 8, "T4 eight SRAM reads");
    chk(wr_sram_n  - base_wr_sram  == 8, "T4 eight SRAM writes");
    chk(cpu_sram_n - base_cpu_sram == 1, "T4 one CPU SRAM transfer");
    chk(header_race_n > base_header_race, "T4 exercised CPU-vs-header same-cycle lock");
    check_alternating_sequence(16, "T4 R/W arbitration");

    $display("[RW] Test 5: single-beat read/write concurrently");
    preload_read_region(32'h0000_0600, 1);
    base_rd_recv = rd_recv_n;
    base_wr_ack  = wr_ack_n;
    rw_seq_n     = 0;
    record_rw_seq = 1'b1;

    fork
      idma_read (32'h0000_0600, 8'd0);
      idma_write(32'h0000_0640, 8'd0, 32'hCC00_0000);
    join

    wait_until_rd_recv("T5 read data", base_rd_recv + 1);
    wait_until_wr_ack("T5 write ack", base_wr_ack + 1);
    wait_cycles(3);
    record_rw_seq = 1'b0;

    check_read_data(base_rd_recv, 32'h0000_0600, 1, "T5");
    check_write_mem(32'h0000_0640, 1, 32'hCC00_0000, "T5");
    check_alternating_sequence(2, "T5 R/W arbitration");

    $display("[RW] Test 6: back-to-back traffic on both channels");
    preload_read_region(32'h0000_0700, 4);
    preload_read_region(32'h0000_0740, 4);
    base_rd_recv = rd_recv_n;
    base_wr_ack  = wr_ack_n;

    fork
      begin
        idma_read(32'h0000_0700, 8'd1);
        idma_read(32'h0000_0740, 8'd1);
      end
      begin
        idma_write(32'h0000_0780, 8'd1, 32'hDD00_0000);
        idma_write(32'h0000_07C0, 8'd1, 32'hEE00_0000);
      end
    join

    wait_until_rd_recv("T6 read data", base_rd_recv + 4);
    wait_until_wr_ack("T6 write acks", base_wr_ack + 4);
    wait_cycles(4);

    check_read_data(base_rd_recv,     32'h0000_0700, 2, "T6 first read");
    check_read_data(base_rd_recv + 2, 32'h0000_0740, 2, "T6 second read");
    check_write_mem(32'h0000_0780, 2, 32'hDD00_0000, "T6 first write");
    check_write_mem(32'h0000_07C0, 2, 32'hEE00_0000, "T6 second write");

    chk(lock_violation_n == 0, "No CPU lock violation observed");

    if (errors == 0)
      $display("[RW] ============ ENDPOINT_RW TB PASSED ============");
    else
      $display("[RW] ============ %0d ERROR(S) ============", errors);

    $finish;
  end

  initial begin
    #100000;
    $display("[RW] !!! STUCK @ %0t", $time);
    $display("  EP rd_state=%0d wr_state=%0d rd_addr=%08x wr_addr=%08x rd_blen=%0d wr_blen=%0d last=%0d",
             i_ep.r_state_q, i_ep.w_state_q, i_ep.read_addr_q, i_ep.write_addr_q,
             i_ep.read_blen_q, i_ep.write_blen_q, i_ep.last_q);
    $display("  grants rd=%b wr=%b cpu=%b wants rd=%b wr=%b burst_starting=%b",
             i_ep.rd_grant, i_ep.wr_grant, i_ep.cpu_grant,
             i_ep.rd_want, i_ep.wr_want, i_ep.burst_starting);
    $display("  SRAM req=%b gnt=%b we=%b addr=%08x wdata=%08x rdata=%08x be=%b",
             sram_req, sram_gnt, sram_we, sram_addr, sram_wdata, sram_rdata, sram_be);
    $display("  RD beat valid=%b gnt=%b rvalid=%b addr=%08x blen=%0d",
             rd_beat_valid, rd_beat_gnt, rd_beat_rvalid, rd_beat_addr, rd_beat_blen);
    $display("  WR beat valid=%b gnt=%b rvalid=%b addr=%08x wdata=%08x blen=%0d",
             wr_beat_valid, wr_beat_gnt, wr_beat_rvalid, wr_beat_addr, wr_beat_wdata, wr_beat_blen);
    $display("  CPU req=%b gnt=%b we=%b rvalid=%b addr=%08x wdata=%08x rdata=%08x",
             cpu_req, cpu_gnt, cpu_we, cpu_rvalid, cpu_addr, cpu_wdata, cpu_rdata);
    $finish;
  end

  initial begin
    $dumpfile("tb_burst_endpoint_rw.vcd");
    $dumpvars(0, tb_burst_endpoint_rw);
  end

endmodule
