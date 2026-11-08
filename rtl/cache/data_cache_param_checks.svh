// SPDX-License-Identifier: SHL-0.51
// Included in data_cache's module scope for elaboration and simulation checks.

    if (NumWays == 0 || (NumWays & (NumWays - 1)) != 0) begin : gen_invalid_ways
        $error("data_cache: NumWays must be a positive power of two.");
    end

    if (LineDataBytes < 16 || (LineDataBytes & (LineDataBytes - 1)) != 0) begin : gen_invalid_line_size
        $error("data_cache: LineDataBytes must be a power of two of at least 16 bytes.");
    end

    if (CacheDataBytes == 0 || NumSets == 0 || (NumSets & (NumSets - 1)) != 0 ||
        CacheDataBytes != NumSets * LineDataBytes * NumWays) begin : gen_invalid_geometry
        $error("data_cache: capacity must contain a positive power-of-two number of complete sets.");
    end

    if (AddrWidth <= OffsetBits + SetBits) begin : gen_invalid_tag_width
        $error("data_cache: AddrWidth must leave at least one cache address-tag bit.");
    end

    if (SramWordsPerWay == 0 || SramWordsPerWay % 256 != 0) begin : gen_invalid_sram_depth
        $error("data_cache: each way must contain a positive multiple of 256 SRAM records.");
    end

    if (CpuDataWidth != 32 || $bits(obi_req_i.a.addr) != AddrWidth ||
        $bits(obi_req_i.a.wdata) != CpuDataWidth ||
        $bits(obi_rsp_o.r.rdata) != CpuDataWidth ||
        $bits(obi_req_i.a.be) != 4) begin : gen_invalid_obi_widths
        $error("data_cache: OBI fields must match AddrWidth and the supported 32-bit data format.");
    end

    if (ObiIdWidth < 1 || $bits(obi_rsp_o.r.rid) != ObiIdWidth) begin : gen_invalid_id_width
        $error("data_cache: OBI request and response ID widths must match.");
    end

    if ($bits(obi_req_i.a.a_optional.ecc) != EccBits ||
        $bits(obi_rsp_o.r.r_optional.ecc) != EccBits ||
        $bits(obi_req_i.a.a_optional.cap_tag) != 1 ||
        $bits(obi_rsp_o.r.r_optional.cap_tag) != 1 ||
        $bits(obi_req_i.a.a_optional.is_cap_access) != 1) begin : gen_invalid_obi_optional_widths
        $error("data_cache: OBI ECC, tag and capability-access fields have unsupported widths.");
    end

    if ($bits(mem_req_o.cmd.line_addr) != AddrWidth ||
        $bits(mem_req_o.cmd.write) != 1 ||
        $bits(mem_req_o.cmd.records) < $clog2(RecordsPerLine + 1)) begin : gen_invalid_mem_command_widths
        $error("data_cache: memory command must match AddrWidth and represent the full line record count.");
    end

    if ($bits(mem_req_o.w.record) != RecordBits ||
        $bits(mem_rsp_i.r.record) != RecordBits ||
        $bits(mem_req_o.w.last) != 1 ||
        $bits(mem_rsp_i.r.last) != 1 ||
        $bits(mem_rsp_i.done.error) != 1) begin : gen_invalid_mem_data_widths
        $error("data_cache: memory streams require complete records, one-bit last and one-bit error fields.");
    end

    if ($bits(mem_req_o.cmd_valid) != 1 || $bits(mem_rsp_i.cmd_ready) != 1 ||
        $bits(mem_req_o.w_valid) != 1 || $bits(mem_rsp_i.w_ready) != 1 ||
        $bits(mem_rsp_i.r_valid) != 1 || $bits(mem_req_o.r_ready) != 1 ||
        $bits(mem_rsp_i.done_valid) != 1 || $bits(mem_req_o.done_ready) != 1) begin : gen_invalid_mem_handshake_widths
        $error("data_cache: memory valid and ready fields must each be one bit wide.");
    end

    // synthesis translate_off
    assert_writeback_success: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        (
            state_q == WAIT_WRITEBACK_DONE &&
            mem_rsp_i.done_valid &&
            mem_req_o.done_ready
        )
        |-> !mem_rsp_i.done.error
    ) else $fatal(
        1,
        "data_cache: writeback failed for set %0d, way %0d; error handling is not implemented",
        set_index,
        selected_way_q
    );

    assert_refill_success: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        (
            state_q == WAIT_REFILL_DONE &&
            mem_rsp_i.done_valid &&
            mem_req_o.done_ready
        )
        |-> !mem_rsp_i.done.error
    ) else $fatal(
        1,
        "data_cache: refill failed for set %0d, way %0d; error handling is not implemented",
        set_index,
        selected_way_q
    );

    assert_cap_store_second_addr: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        (
            (state_q == CACHE_LOOKUP ||
            state_q == WAIT_FOR_SECOND_WORD) &&
            obi_is_cap_access_q &&
            obi_req_write_q &&
            obi_req_i.req &&
            obi_rsp_o.gnt
        )
        |-> (obi_req_i.a.addr == obi_req_addr_q + AddrWidth'(4))
    ) else $fatal(
        1,
        "Capability store: expected second address 0x%0h, got 0x%0h",
        obi_req_addr_q + AddrWidth'(4),
        obi_req_i.a.addr
    );

    assert_write_be_nonzero: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        (obi_req_i.req && obi_rsp_o.gnt && obi_req_i.a.we)
        |-> (obi_req_i.a.be != '0)
        ) else $fatal(
            1,
            "data_cache: accepted write with empty byte enable"
        );
    // synthesis translate_on
