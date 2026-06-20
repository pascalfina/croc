module croc_burst_dma 
import croc_pkg::*; 
import burst_pkg::burst_hdr_t;
import burst_pkg::burst_req_t;
import burst_pkg::burst_rsp_t;

(
    input  logic clk_i, 
    input  logic rst_ni,

    // iDMA-read and write ports
    input  sbr_obi_req_t idma_read_req_i,   
    output sbr_obi_rsp_t idma_read_rsp_o,
    input  sbr_obi_req_t idma_write_req_i,  
    output sbr_obi_rsp_t idma_write_rsp_o,

    // CPU streams
    input  sbr_obi_req_t cpu_bank0_req_i,   
    output sbr_obi_rsp_t cpu_bank0_rsp_o,
    input  sbr_obi_req_t cpu_bank1_req_i,   
    output sbr_obi_rsp_t cpu_bank1_rsp_o,

    // sram bank 0
    output logic bank0_req_o, bank0_we_o,  
    output logic [31:0] bank0_addr_o, bank0_wdata_o,
    output logic [3:0] bank0_be_o,         
    input  logic [31:0] bank0_rdata_i,

    // sram bank 1
    output logic bank1_req_o, bank1_we_o,  
    output logic [31:0] bank1_addr_o, bank1_wdata_o,
    output logic [3:0] bank1_be_o,         
    input  logic [31:0] bank1_rdata_i

);

localparam int BANK_BIT = 11;

// read signals for compressor
logic rd_beat_valid, rd_beat_we, rd_beat_bfirst, rd_beat_blast, rd_beat_gnt, rd_beat_rvalid;
logic [31:0] rd_beat_addr, rd_beat_wdata, rd_beat_rdata;
logic [BurstLenWidth-1:0] rd_beat_blen;
  
burst_req_t rd_req; //from compressor
burst_rsp_t rd_rsp; //to compressor


// write signals for compressor
logic wr_beat_valid, wr_beat_we, wr_beat_bfirst, wr_beat_blast, wr_beat_gnt, wr_beat_rvalid;
logic [31:0] wr_beat_addr, wr_beat_wdata, wr_beat_rdata;
logic [BurstLenWidth-1:0] wr_beat_blen;

burst_req_t wr_req; //from compressor
burst_rsp_t wr_rsp; //to compressor

// adapter obi - read
assign rd_beat_valid  = idma_read_req_i.req;
assign rd_beat_addr = idma_read_req_i.a.a_optional.start_addr;
assign rd_beat_wdata  = idma_read_req_i.a.wdata;
assign rd_beat_we     = idma_read_req_i.a.we;
assign rd_beat_bfirst = idma_read_req_i.a.a_optional.bfirst;
assign rd_beat_blast  = idma_read_req_i.a.a_optional.blast;
assign rd_beat_blen   = idma_read_req_i.a.a_optional.blen;
assign idma_read_rsp_o.gnt     = rd_beat_gnt;
assign idma_read_rsp_o.rvalid  = rd_beat_rvalid;
assign idma_read_rsp_o.r.rdata = rd_beat_rdata;
assign idma_read_rsp_o.r.err   = 1'b0;
assign idma_read_rsp_o.r.r_optional = '0;

burst_compressor read_burst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .beat_valid_i(rd_beat_valid),
    .beat_gnt_o(rd_beat_gnt),
    .beat_addr_i(rd_beat_addr),
    .beat_wdata_i(rd_beat_wdata),
    .beat_we_i(rd_beat_we),
    .beat_bfirst_i(rd_beat_bfirst),
    .beat_blast_i(rd_beat_blast),
    .beat_blen_i(rd_beat_blen),
    .beat_rdata_o(rd_beat_rdata),
    .beat_rvalid_o(rd_beat_rvalid),
    .burst_req_o(rd_req),
    .burst_rsp_i(rd_rsp)
);

// adapter obi - write
assign wr_beat_valid  = idma_write_req_i.req;
assign wr_beat_addr = idma_write_req_i.a.a_optional.start_addr;
assign wr_beat_wdata  = idma_write_req_i.a.wdata;
assign wr_beat_we     = idma_write_req_i.a.we;
assign wr_beat_bfirst = idma_write_req_i.a.a_optional.bfirst;
assign wr_beat_blast  = idma_write_req_i.a.a_optional.blast;
assign wr_beat_blen   = idma_write_req_i.a.a_optional.blen;
assign idma_write_rsp_o.gnt     = wr_beat_gnt;
assign idma_write_rsp_o.rvalid  = wr_beat_rvalid;
assign idma_write_rsp_o.r.rdata = wr_beat_rdata;
assign idma_write_rsp_o.r.err   = 1'b0;
assign idma_write_rsp_o.r.r_optional = '0;


burst_compressor write_burst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .beat_valid_i(wr_beat_valid),
    .beat_gnt_o(wr_beat_gnt),
    .beat_addr_i(wr_beat_addr),
    .beat_wdata_i(wr_beat_wdata),
    .beat_we_i(wr_beat_we),
    .beat_bfirst_i(wr_beat_bfirst),
    .beat_blast_i(wr_beat_blast),
    .beat_blen_i(wr_beat_blen),
    .beat_rdata_o(wr_beat_rdata),
    .beat_rvalid_o(wr_beat_rvalid),
    .burst_req_o(wr_req),
    .burst_rsp_i(wr_rsp)
);



burst_req_t b0_rd_req, b1_rd_req, b0_wr_req, b1_wr_req;   // zu den Endpoints
burst_rsp_t b0_rd_rsp, b1_rd_rsp, b0_wr_rsp, b1_wr_rsp;   // von den Endpoints

/// bank routing from read compressor ///

burst_hdr_t rd_pending_hdr_q;
logic       rd_pending_q;
logic       rd_pending_bank_q;
logic       rd_active_bank_q;

always_comb begin
    b0_rd_req = '0;
    b1_rd_req = '0;
    rd_rsp = '0;

    // Route an active burst only through the bank selected at header acceptance.
    if (rd_active_bank_q == 1'b0) begin
        b0_rd_req.rready = rd_req.rready;
        rd_rsp.rdata     = b0_rd_rsp.rdata;
        rd_rsp.rvalid    = b0_rd_rsp.rvalid;
    end else begin
        b1_rd_req.rready = rd_req.rready;
        rd_rsp.rdata     = b1_rd_rsp.rdata;
        rd_rsp.rvalid    = b1_rd_rsp.rvalid;
    end

    // A new header crosses a register boundary before reaching an endpoint.
    if (rd_pending_q) begin
        if (rd_pending_bank_q == 1'b0) begin
            b0_rd_req.hdr       = rd_pending_hdr_q;
            b0_rd_req.hdr_valid = 1'b1;
            rd_rsp.hdr_gnt      = b0_rd_rsp.hdr_gnt;
        end else begin
            b1_rd_req.hdr       = rd_pending_hdr_q;
            b1_rd_req.hdr_valid = 1'b1;
            rd_rsp.hdr_gnt      = b1_rd_rsp.hdr_gnt;
        end
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        rd_pending_hdr_q  <= '0;
        rd_pending_q      <= 1'b0;
        rd_pending_bank_q <= 1'b0;
        rd_active_bank_q  <= 1'b0;
    end else begin
        if (!rd_pending_q && rd_req.hdr_valid) begin
            rd_pending_hdr_q  <= rd_req.hdr;
            rd_pending_bank_q <= rd_req.hdr.start_addr[BANK_BIT];
            rd_pending_q      <= 1'b1;
        end else if (rd_pending_q &&
                     ((!rd_pending_bank_q && b0_rd_rsp.hdr_gnt) ||
                      ( rd_pending_bank_q && b1_rd_rsp.hdr_gnt))) begin
            rd_active_bank_q <= rd_pending_bank_q;
            rd_pending_q     <= 1'b0;
        end
    end 
end

/// bank routing from write compressor ///

burst_hdr_t wr_pending_hdr_q;
logic       wr_pending_q;
logic       wr_pending_bank_q;
logic       wr_active_bank_q;

always_comb begin
    b0_wr_req = '0;
    b1_wr_req = '0;
    wr_rsp = '0;

    // Route write data and acknowledgements through the accepted burst bank.
    if (wr_active_bank_q == 1'b0) begin
        b0_wr_req.wdata  = wr_req.wdata;
        b0_wr_req.wvalid = wr_req.wvalid;
        wr_rsp.wready    = b0_wr_rsp.wready;
        wr_rsp.rdata     = b0_wr_rsp.rdata;
        wr_rsp.rvalid    = b0_wr_rsp.rvalid;
    end else begin
        b1_wr_req.wdata  = wr_req.wdata;
        b1_wr_req.wvalid = wr_req.wvalid;
        wr_rsp.wready    = b1_wr_rsp.wready;
        wr_rsp.rdata     = b1_wr_rsp.rdata;
        wr_rsp.rvalid    = b1_wr_rsp.rvalid;
    end

    // A new header crosses a register boundary before reaching an endpoint.
    if (wr_pending_q) begin
        if (wr_pending_bank_q == 1'b0) begin
            b0_wr_req.hdr       = wr_pending_hdr_q;
            b0_wr_req.hdr_valid = 1'b1;
            wr_rsp.hdr_gnt      = b0_wr_rsp.hdr_gnt;
        end else begin
            b1_wr_req.hdr       = wr_pending_hdr_q;
            b1_wr_req.hdr_valid = 1'b1;
            wr_rsp.hdr_gnt      = b1_wr_rsp.hdr_gnt;
        end
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        wr_pending_hdr_q  <= '0;
        wr_pending_q      <= 1'b0;
        wr_pending_bank_q <= 1'b0;
        wr_active_bank_q  <= 1'b0;
    end else begin
        if (!wr_pending_q && wr_req.hdr_valid) begin
            wr_pending_hdr_q  <= wr_req.hdr;
            wr_pending_bank_q <= wr_req.hdr.start_addr[BANK_BIT];
            wr_pending_q      <= 1'b1;
        end else if (wr_pending_q &&
                     ((!wr_pending_bank_q && b0_wr_rsp.hdr_gnt) ||
                      ( wr_pending_bank_q && b1_wr_rsp.hdr_gnt))) begin
            wr_active_bank_q <= wr_pending_bank_q;
            wr_pending_q     <= 1'b0;
        end
    end 
end


// bank 0
assign cpu_bank0_rsp_o.r.err        = 1'b0;
assign cpu_bank0_rsp_o.r.r_optional = '0;
// bank 1
assign cpu_bank1_rsp_o.r.err        = 1'b0;
assign cpu_bank1_rsp_o.r.r_optional = '0;

localparam int unsigned RidFifoDepth = 8;   // >= max outstanding (NumAxInFlight + Pipeline)

logic [SbrObiCfg.IdWidth-1:0] rd_rid, wr_rid;

fifo_v3 #(
    .FALL_THROUGH (1'b0),
    .DATA_WIDTH   (SbrObiCfg.IdWidth),
    .DEPTH        (RidFifoDepth)
) i_rd_rid_fifo (
    .clk_i (clk_i), .rst_ni (rst_ni),
    .flush_i (1'b0), .testmode_i (1'b0),
    .full_o (), .empty_o (), .usage_o (),
    .data_i (idma_read_req_i.a.aid),
    .push_i (idma_read_req_i.req && idma_read_rsp_o.gnt),   
    .data_o (rd_rid),
    .pop_i  (idma_read_rsp_o.rvalid)                        
);
assign idma_read_rsp_o.r.rid = rd_rid;

fifo_v3 #(
    .FALL_THROUGH (1'b0),
    .DATA_WIDTH   (SbrObiCfg.IdWidth),
    .DEPTH        (RidFifoDepth)
) i_wr_rid_fifo (
    .clk_i (clk_i), .rst_ni (rst_ni),
    .flush_i (1'b0), .testmode_i (1'b0),
    .full_o (), .empty_o (), .usage_o (),
    .data_i (idma_write_req_i.a.aid),
    .push_i (idma_write_req_i.req && idma_write_rsp_o.gnt),
    .data_o (wr_rid),
    .pop_i  (idma_write_rsp_o.rvalid)
);
assign idma_write_rsp_o.r.rid = wr_rid;


logic [SbrObiCfg.IdWidth-1:0] b0_rid_q, b1_rid_q;
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        b0_rid_q <= '0; b1_rid_q <= '0;
    end else begin
        if (cpu_bank0_req_i.req && cpu_bank0_rsp_o.gnt) b0_rid_q <= cpu_bank0_req_i.a.aid;
        if (cpu_bank1_req_i.req && cpu_bank1_rsp_o.gnt) b1_rid_q <= cpu_bank1_req_i.a.aid;
    end
end



assign cpu_bank0_rsp_o.r.rid = b0_rid_q;
assign cpu_bank1_rsp_o.r.rid = b1_rid_q;



burst_endpoint_rw endpoint_sram_bank_0 (
    .clk_i(clk_i), 
    .rst_ni(rst_ni),
    .rd_req_i(b0_rd_req), 
    .rd_rsp_o(b0_rd_rsp),
    .wr_req_i(b0_wr_req), 
    .wr_rsp_o(b0_wr_rsp),
    .cpu_req_i(cpu_bank0_req_i.req),     
    .cpu_we_i(cpu_bank0_req_i.a.we),
    .cpu_addr_i(cpu_bank0_req_i.a.addr),  
    .cpu_wdata_i(cpu_bank0_req_i.a.wdata),
    .cpu_be_i(cpu_bank0_req_i.a.be),
    .cpu_gnt_o(cpu_bank0_rsp_o.gnt),     
    .cpu_rvalid_o(cpu_bank0_rsp_o.rvalid),
    .cpu_rdata_o(cpu_bank0_rsp_o.r.rdata),
    .sram_req_o(bank0_req_o), 
    .sram_we_o(bank0_we_o), 
    .sram_addr_o(bank0_addr_o),
    .sram_wdata_o(bank0_wdata_o), 
    .sram_be_o(bank0_be_o),
    .sram_gnt_i(1'b1), 
    .sram_rdata_i(bank0_rdata_i)
);

burst_endpoint_rw endpoint_sram_bank_1 (
    .clk_i(clk_i), 
    .rst_ni(rst_ni),
    .rd_req_i(b1_rd_req), 
    .rd_rsp_o(b1_rd_rsp),
    .wr_req_i(b1_wr_req), 
    .wr_rsp_o(b1_wr_rsp),
    .cpu_req_i(cpu_bank1_req_i.req),     
    .cpu_we_i(cpu_bank1_req_i.a.we),
    .cpu_addr_i(cpu_bank1_req_i.a.addr),  
    .cpu_wdata_i(cpu_bank1_req_i.a.wdata),
    .cpu_be_i(cpu_bank1_req_i.a.be),
    .cpu_gnt_o(cpu_bank1_rsp_o.gnt),     
    .cpu_rvalid_o(cpu_bank1_rsp_o.rvalid),
    .cpu_rdata_o(cpu_bank1_rsp_o.r.rdata),
    .sram_req_o(bank1_req_o), 
    .sram_we_o(bank1_we_o), 
    .sram_addr_o(bank1_addr_o),
    .sram_wdata_o(bank1_wdata_o), 
    .sram_be_o(bank1_be_o),
    .sram_gnt_i(1'b1), 
    .sram_rdata_i(bank1_rdata_i)
);


endmodule
