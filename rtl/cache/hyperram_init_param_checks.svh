// SPDX-License-Identifier: SHL-0.51
// Included in hyperram_init's module scope for elaboration checks.

    localparam unsigned CheckMaxBurstRecords = (NumBursts > 1)
        ? NumbRecordsStandard : NumbRecordsLast;
    localparam unsigned CheckRecordCountWidth = (CheckMaxBurstRecords > 0)
        ? $clog2(CheckMaxBurstRecords + 1) : 1;
    localparam unsigned CheckRangeWidth = ((AddrWidth > 32) ? AddrWidth : 32) + 1;
    localparam logic [CheckRangeWidth-1:0] CheckRangeEnd =
        CheckRangeWidth'(LogicalBaseAddr) + CheckRangeWidth'(InitDataBytes);
    localparam logic [CheckRangeWidth-1:0] CheckAddressLimit =
        CheckRangeWidth'(1) << AddrWidth;

    if (InitDataBytes == 0 ||
        InitDataBytes % (2 * cache_pkg::CacheRecordDataBytes) != 0) begin : gen_invalid_init_size
        $error("hyperram_init: InitDataBytes must be a positive multiple of 16 logical bytes.");
    end

    if (InitBurstDataBytes == 0 ||
        InitBurstDataBytes % (2 * cache_pkg::CacheRecordDataBytes) != 0) begin : gen_invalid_burst_size
        $error("hyperram_init: InitBurstDataBytes must be a positive multiple of 16 logical bytes.");
    end

    if (AddrWidth < 4 ||
        LogicalBaseAddr % (2 * cache_pkg::CacheRecordDataBytes) != 0) begin : gen_invalid_base_address
        $error("hyperram_init: AddrWidth must be at least 4 and LogicalBaseAddr must be 16-byte aligned.");
    end

    if (CheckRangeEnd > CheckAddressLimit) begin : gen_invalid_address_range
        $error("hyperram_init: the initialization region exceeds the address space configured by AddrWidth.");
    end

    if (cache_pkg::CacheWordDataBits != 32 || cache_pkg::CacheEccBits != 7 ||
        cache_pkg::CacheRecordDataBytes != 8 || cache_pkg::CacheRecordBits != 80) begin : gen_invalid_record_format
        $error("hyperram_init: the constant initialization pattern requires 80-bit records with 32-bit data and 7-bit ECC per word.");
    end

    if ($bits(mem_req_o.cmd.line_addr) != AddrWidth ||
        $bits(mem_req_o.cmd.write) != 1 ||
        $bits(mem_req_o.cmd.records) < CheckRecordCountWidth) begin : gen_invalid_mem_command_widths
        $error("hyperram_init: memory command widths must match AddrWidth and represent the largest initialization burst record count.");
    end

    if ($bits(mem_req_o.w.record) != cache_pkg::CacheRecordBits ||
        $bits(mem_req_o.w.record.lower.data) != cache_pkg::CacheWordDataBits ||
        $bits(mem_req_o.w.record.upper.data) != cache_pkg::CacheWordDataBits ||
        $bits(mem_req_o.w.record.lower.ecc) != cache_pkg::CacheEccBits ||
        $bits(mem_req_o.w.record.upper.ecc) != cache_pkg::CacheEccBits ||
        $bits(mem_req_o.w.record.lower.cap_tag) != 1 ||
        $bits(mem_req_o.w.record.upper.cap_tag) != 1 ||
        $bits(mem_req_o.w_strb) != cache_pkg::CacheRecordBits / 8 ||
        $bits(mem_req_o.w.last) != 1) begin : gen_invalid_mem_data_widths
        $error("hyperram_init: write data must contain complete cache records, one strobe per physical byte and a one-bit last field.");
    end

    if ($bits(mem_req_o.cmd_valid) != 1 || $bits(mem_rsp_i.cmd_ready) != 1 ||
        $bits(mem_req_o.w_valid) != 1 || $bits(mem_rsp_i.w_ready) != 1 ||
        $bits(mem_req_o.done_ready) != 1 || $bits(mem_rsp_i.done_valid) != 1 ||
        $bits(mem_rsp_i.done.error) != 1) begin : gen_invalid_mem_handshake_widths
        $error("hyperram_init: memory handshakes and completion error must each be one bit wide.");
    end

    // The current midend counts each transfer in 16-bit PHY words.
    localparam longint unsigned CheckMaxBurstPhyWords =
        (longint'(CheckMaxBurstRecords) * cache_pkg::CacheRecordBits) / 16;
    if ($clog2(CheckMaxBurstPhyWords + 1) > hyperbus_pkg::HyperBurstWidth) begin : gen_invalid_host_burst_length
        $error("hyperram_init: initialization burst exceeds the HyperBus midend's PHY-word count field.");
    end
