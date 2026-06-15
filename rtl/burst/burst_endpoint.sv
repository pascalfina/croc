module burst_endpoint import burst_pkg::*; (
  input  logic                   clk_i,
  input  logic                   rst_ni,

  // ── SEITE A: Burst-Protokoll (vom iDMA/Compressor) ──
  input  burst_req_t             burst_req_i,   // hdr, hdr_valid, wdata, wvalid, rready
  output burst_rsp_t             burst_rsp_o,   // hdr_gnt, wready, rdata, rvalid

  // ── SEITE B: SRAM (wie heute obi_sram_shim) ──
  output logic                   sram_req_o,
  output logic                   sram_we_o,
  output logic [AddrWidth-1:0]   sram_addr_o,
  output logic [DataWidth-1:0]   sram_wdata_o,
  output logic [DataWidth/8-1:0] sram_be_o,
  input  logic                   sram_gnt_i,
  input  logic [DataWidth-1:0]   sram_rdata_i
);

logic [AddrWidth-1:0] addr_d, addr_q;
logic [BurstLenWidth-1:0] blen_d, blen_q; 

typedef enum logic [1:0] {
    IDLE,
    WRITE
} state_t;

state_t state_d, state_q;

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


    case (state_q)
        IDLE: begin
            if(burst_req_i.hdr_valid && burst_req_i.hdr.we)begin
                addr_d = burst_req_i.hdr.start_addr;
                blen_d = burst_req_i.hdr.blen;
                burst_rsp_o.hdr_gnt = 1;
                state_d = WRITE;
            end
            else begin
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
    end

    else begin
        state_q <= state_d;
        addr_q <= addr_d;
        blen_q <= blen_d;
    end 
end



endmodule