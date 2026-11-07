// SPDX-License-Identifier: SHL-0.51
// Included in data_cache's parameter and port scope for elaboration checks.

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
