module burst_endpoint import burst_pkg::*; (
  input  logic                   clk_i,
  input  logic                   rst_ni,

  // Burst-Protokoll from iDMA/Compressor
  input  burst_req_t             burst_req_i,   // hdr, hdr_valid, wdata, wvalid, rready
  output burst_rsp_t             burst_rsp_o,   // hdr_gnt, wready, rdata, rvalid

  // SRAM side 
  output logic                   sram_req_o,
  output logic                   sram_we_o,
  output logic [AddrWidth-1:0]   sram_addr_o,
  output logic [DataWidth-1:0]   sram_wdata_o,
  output logic [DataWidth/8-1:0] sram_be_o,
  input  logic                   sram_gnt_i,
  input  logic [DataWidth-1:0]   sram_rdata_i,

  // cpu direct communication with sram 
  input  logic                   cpu_req_i,
  input  logic                   cpu_we_i,
  input  logic [AddrWidth-1:0]   cpu_addr_i,
  input  logic [DataWidth-1:0]   cpu_wdata_i,
  input  logic [DataWidth/8-1:0] cpu_be_i,
  output logic                   cpu_gnt_o,
  output logic [DataWidth-1:0]   cpu_rdata_o,
  output logic                   cpu_rvalid_o
);

logic [AddrWidth-1:0] addr_d, addr_q;
logic [BurstLenWidth-1:0] blen_d, blen_q; 
logic cpu_rvalid_d, cpu_rvalid_q;

typedef enum logic [1:0] {
    IDLE,
    WRITE,
    READ_ADDR,
    READ_DATA
} state_t;

state_t state_d, state_q;

assign cpu_rvalid_o = cpu_rvalid_q;
assign cpu_rdata_o = sram_rdata_i;

always_comb begin
    state_d = state_q;
    addr_d = addr_q;
    blen_d = blen_q;
    sram_req_o = 0;
    sram_we_o = 0;
    sram_addr_o = addr_q;
    sram_wdata_o = 32'd0;
    sram_be_o = 4'd0;
    burst_rsp_o = '0;
    cpu_gnt_o = 0;
    cpu_rvalid_d = 0;

    case (state_q)

        IDLE: begin
            if(burst_req_i.hdr_valid)begin
                addr_d = burst_req_i.hdr.start_addr;
                blen_d = burst_req_i.hdr.blen;
                burst_rsp_o.hdr_gnt = 1;
                if (burst_req_i.hdr.we) begin
                    state_d = WRITE;
                end else begin
                    state_d = READ_ADDR;
                end
            end else if (cpu_req_i) begin // burst is idle cpu can directly write to sram
                sram_req_o = cpu_req_i;
                sram_we_o = cpu_we_i;
                sram_addr_o = cpu_addr_i;
                sram_be_o = cpu_be_i;
                cpu_gnt_o = sram_gnt_i;
                sram_wdata_o = cpu_wdata_i;
                cpu_rvalid_d = !cpu_we_i && sram_gnt_i;
            end else begin
                state_d = IDLE; // useless only for clarity 
            end
        end

        WRITE: begin
            if(burst_req_i.wvalid)begin //write data valid  
                sram_req_o = 1;
                sram_we_o = 1;
                sram_addr_o = addr_q;
                sram_wdata_o = burst_req_i.wdata; 
                sram_be_o = 4'b1111;
            end
            if(sram_gnt_i && burst_req_i.wvalid)begin
                addr_d = addr_q + 4;
                burst_rsp_o.wready = 1;
                if(blen_q == 0)begin
                    state_d = IDLE;
                end else begin 
                    blen_d = blen_q - 1;
                end   
            end 
        end

        READ_ADDR: begin
            sram_req_o = 1;
            sram_we_o = 0; 
            sram_addr_o = addr_q;
            if (sram_gnt_i) begin
                state_d = READ_DATA;
            end 
        end

        READ_DATA: begin
            burst_rsp_o.rvalid = 1;
            burst_rsp_o.rdata = sram_rdata_i;
            if (burst_req_i.rready) begin
                if(blen_q == 0) begin
                    state_d = IDLE;
                end else begin
                    addr_d = addr_q + 4;
                    blen_d = blen_q - 1;
                    state_d = READ_ADDR;
                    end
                end
            end

        default: begin
            state_d = IDLE;
        end
    endcase
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni)begin
        state_q <= IDLE;
        addr_q <= 32'h0;
        blen_q <= 8'd0;
        cpu_rvalid_q <= 0;
    end else begin
        state_q <= state_d;
        addr_q <= addr_d;
        blen_q <= blen_d;
        cpu_rvalid_q <= cpu_rvalid_d;
    end 
end

endmodule