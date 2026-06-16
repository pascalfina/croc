module burst_compressor import burst_pkg::*; (
  input  logic                   clk_i,
  input  logic                   rst_ni,

    // iDMA-Beat-Side 
  input  logic                     beat_valid_i,   // Beat is there (req)
  output logic                     beat_gnt_o,     // Compressor accepts the beat
  input  logic [AddrWidth-1:0]     beat_addr_i,    // only bfirst-Beat -> Header
  input  logic [DataWidth-1:0]     beat_wdata_i,
  input  logic                     beat_we_i,
  input  logic                     beat_bfirst_i,
  input  logic                     beat_blast_i,
  input  logic [BurstLenWidth-1:0] beat_blen_i,
  output logic [DataWidth-1:0]     beat_rdata_o,   // Read-Daten zurueck zum iDMA
  output logic                     beat_rvalid_o,

  // Burst-Protokoll-Side -> endpoint 
  output burst_req_t               burst_req_o,    // hdr, hdr_valid, wdata, wvalid, rready
  input  burst_rsp_t               burst_rsp_i     // hdr_gnt, wready, rdata, rvalid

);

assign beat_rvalid_o = burst_rsp_i.rvalid;   
assign beat_rdata_o  = burst_rsp_i.rdata;     


typedef enum logic [1:0] {
    IDLE,
    STREAM,
    READ_STREAM
} state_t;

state_t state_d, state_q;
logic [BurstLenWidth-1:0] count_d, count_q;

always_comb begin

    state_d = state_q;
    beat_gnt_o = 0;
    burst_req_o = '0;
    count_d = count_q;

    case (state_q)
        
        IDLE:begin
            if(beat_valid_i && beat_bfirst_i)begin
                burst_req_o.hdr_valid = 1;
                burst_req_o.hdr.start_addr = beat_addr_i;
                burst_req_o.hdr.blen = beat_blen_i;
                count_d = beat_blen_i;
                burst_req_o.hdr.we = beat_we_i;
                if (burst_rsp_i.hdr_gnt) begin
                    if (beat_we_i) state_d = STREAM;
                    else           state_d = READ_STREAM;  
                end else begin
                    state_d = IDLE; //useless 
                end
            end
        end

        STREAM: begin
            burst_req_o.wvalid = beat_valid_i;
            burst_req_o.wdata = beat_wdata_i;
            if (burst_rsp_i.wready) begin
                beat_gnt_o = 1;
                if (beat_blast_i) state_d = IDLE;
                else              state_d = STREAM;
            end
        end

        READ_STREAM: begin
            burst_req_o.rready = 1; 
            beat_gnt_o = beat_valid_i;
            if (burst_rsp_i.rvalid) begin
                if(count_q > 0)begin
                    count_d = count_q - 1;
                end else begin
                    state_d = IDLE;
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
        count_q <= 0;
    end else begin
        state_q <= state_d;
        count_q <= count_d;
    end 
end

endmodule