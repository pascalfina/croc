// SPDX-License-Identifier: SHL-0.51
// Included in instruction_cache's module scope for elaboration and simulation checks.

    if (NumWays == 0 || (NumWays & (NumWays - 1)) != 0) begin : gen_invalid_ways
        $error("instruction_cache: NumWays must be a positive power of two.");
    end

    if (LineDataBytes < 16 || (LineDataBytes & (LineDataBytes - 1)) != 0) begin : gen_invalid_line_size
        $error("instruction_cache: LineDataBytes must be a power of two of at least 16 bytes.");
    end

    if (CacheDataBytes == 0 || NumSets == 0 || (NumSets & (NumSets - 1)) != 0 ||
        CacheDataBytes != NumSets * LineDataBytes * NumWays) begin : gen_invalid_geometry
        $error("instruction_cache: capacity must contain a positive power-of-two number of complete sets.");
    end

    if (AddrWidth <= OffsetBits + SetBits) begin : gen_invalid_tag_width
        $error("instruction_cache: AddrWidth must leave at least one cache address-tag bit.");
    end

    if (SramWords == 0 || SramWords % 256 != 0) begin : gen_invalid_sram_depth
        $error("instruction_cache: all ways together must hold a positive multiple of 256 SRAM records.");
    end

    if (CpuDataWidth != 32 || $bits(obi_req_i.a.addr) != AddrWidth ||
        $bits(obi_rsp_o.r.rdata) != CpuDataWidth ||
        $bits(obi_req_i.a.we) != 1) begin : gen_invalid_obi_widths
        $error("instruction_cache: OBI fields must match AddrWidth and the supported 32-bit data format.");
    end

    if (ObiIdWidth < 1 || $bits(obi_rsp_o.r.rid) != ObiIdWidth) begin : gen_invalid_id_width
        $error("instruction_cache: OBI request and response ID widths must match.");
    end

    if ($bits(obi_rsp_o.r.r_optional.ecc) != EccBits) begin : gen_invalid_obi_ecc_width
        $error("instruction_cache: OBI response ECC width must match the cache word format.");
    end

    if ($bits(mem_req_o.cmd.line_addr) != AddrWidth ||
        $bits(mem_req_o.cmd.write) != 1 ||
        $bits(mem_req_o.cmd.records) < $clog2(RecordsPerLine + 1)) begin : gen_invalid_mem_command_widths
        $error("instruction_cache: memory command must match AddrWidth and represent the full line record count.");
    end

    if ($bits(mem_rsp_i.r.record) != RecordBits ||
        $bits(mem_rsp_i.r.last) != 1 ||
        $bits(mem_rsp_i.done.error) != 1) begin : gen_invalid_mem_data_widths
        $error("instruction_cache: memory responses require complete records, one-bit last and one-bit error fields.");
    end

    if ($bits(mem_req_o.cmd_valid) != 1 || $bits(mem_rsp_i.cmd_ready) != 1 ||
        $bits(mem_rsp_i.r_valid) != 1 || $bits(mem_req_o.r_ready) != 1 ||
        $bits(mem_rsp_i.done_valid) != 1 || $bits(mem_req_o.done_ready) != 1) begin : gen_invalid_mem_handshake_widths
        $error("instruction_cache: memory valid and ready fields must each be one bit wide.");
    end

    // synthesis translate_off
    assert_fetch_read_only: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        (obi_req_i.req && obi_rsp_o.gnt) |-> !obi_req_i.a.we
    ) else $fatal(
        1,
        "instruction_cache: accepted a write on the instruction port"
    );

    assert_fetch_word_aligned: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        (obi_req_i.req && obi_rsp_o.gnt) |-> (obi_req_i.a.addr[1:0] == 2'b00)
    ) else $fatal(
        1,
        "instruction_cache: fetch address 0x%0h must be word-aligned",
        obi_req_i.a.addr
    );

    assert_refill_last: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        (
            state_q == WAIT_REFILL_DATA &&
            mem_rsp_i.r_valid && mem_req_o.r_ready
        )
        |-> (mem_rsp_i.r.last == (int'(line_record_index_q) == RecordsPerLine - 1))
    ) else $fatal(
        1,
        "instruction_cache: unexpected refill last at record %0d of %0d",
        line_record_index_q,
        RecordsPerLine
    );

    // Catch early error completions too, even before done_ready is asserted.
    assert_refill_success: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        (
            (state_q == WAIT_REFILL_DATA || state_q == WAIT_REFILL_DONE) &&
            mem_rsp_i.done_valid
        )
        |-> !mem_rsp_i.done.error
    ) else $fatal(
        1,
        "instruction_cache: refill failed for set %0d, way %0d; error handling is not implemented",
        set_index,
        selected_way_q
    );

`ifndef SYNTHESIS
    // Coverage counters, reported at the end of simulation. A fresh lookup
    // follows IDLE; the replay lookup after a refill is not counted again.
    state_t      cov_prev_state_q;
    logic        cov_cmd_waiting_q;
    int unsigned cov_fetches, cov_hits, cov_misses, cov_miss_invalid, cov_miss_valid;
    int unsigned cov_refills, cov_cmd_waits, cov_cmd_wait_cycles;

    always @(posedge clk_i) begin
        if (rst_ni) begin
            if (state_q == IDLE && obi_req_i.req && obi_rsp_o.gnt) cov_fetches++;
            if (state_q == IDLE && obi_req_i.req && obi_rsp_o.gnt && state_d != CACHE_LOOKUP) cov_hits++;

            if (state_q == CACHE_LOOKUP && cov_prev_state_q == IDLE) begin
                if (hit_found) begin
                    cov_hits++;
                end else begin
                    cov_misses++;
                    if (cache_meta_q[set_index][selected_way_d].valid) cov_miss_valid++;
                    else                                               cov_miss_invalid++;
                end
            end

            if (state_q != cov_prev_state_q && state_q == SEND_REFILL_CMD) cov_refills++;

            if (mem_req_o.cmd_valid && !mem_rsp_i.cmd_ready) begin
                cov_cmd_wait_cycles++;
                if (!cov_cmd_waiting_q) cov_cmd_waits++;
            end
        end
        cov_prev_state_q  <= state_q;
        cov_cmd_waiting_q <= rst_ni && mem_req_o.cmd_valid && !mem_rsp_i.cmd_ready;
    end

    final begin
        $display("[CACHE-COV] %m: %0d fetches, %0d hits, %0d misses (victim invalid %0d, evicted %0d), %0d refills",
                 cov_fetches, cov_hits, cov_misses, cov_miss_invalid, cov_miss_valid, cov_refills);
        $display("[CACHE-COV] %m: %0d line commands waited for the arbiter (%0d cycles)",
                 cov_cmd_waits, cov_cmd_wait_cycles);
    end
`endif
    // synthesis translate_on
