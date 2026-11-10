// Included in jtag_hyperram_adapter's module scope for elaboration checks.

    if (ObiDataWidth != 32) begin : gen_invalid_data_width
        $error("jtag_hyperram_adapter supports only 32-bit OBI data.");
    end

    if (BlockDataBytes < 16 || (BlockDataBytes & (BlockDataBytes - 1)) != 0 ||
        AddrWidth <= BlockOffsetBits) begin : gen_invalid_block_size
        $error("jtag_hyperram_adapter requires a power-of-two block size of at least 16 bytes fitting AddrWidth.");
    end

    if ($bits(obi_req_i.a.addr) != AddrWidth ||
        $bits(obi_req_i.a.wdata) != ObiDataWidth ||
        $bits(obi_req_i.a.be) != ObiDataWidth / 8 ||
        $bits(obi_rsp_o.r.rdata) != ObiDataWidth ||
        $bits(obi_req_i.a.aid) != $bits(obi_rsp_o.r.rid) ||
        $bits(obi_rsp_o.r.r_optional.ecc) != cache_pkg::CacheEccBits) begin : gen_invalid_obi_fields
        $error("jtag_hyperram_adapter: OBI field widths do not match the supported configuration.");
    end

    if ($bits(mem_req_o.cmd.line_addr) != AddrWidth ||
        $bits(mem_req_o.cmd.records) < $clog2(RecordsPerBlock + 1) ||
        $bits(mem_req_o.w.record) != cache_pkg::CacheRecordBits ||
        $bits(mem_rsp_i.r.record) != cache_pkg::CacheRecordBits ||
        $bits(mem_req_o.w_strb) != cache_pkg::CacheRecordBits / 8) begin : gen_invalid_mem_fields
        $error("jtag_hyperram_adapter: memory interface cannot represent the configured block.");
    end
