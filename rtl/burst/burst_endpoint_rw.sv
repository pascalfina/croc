module burst_endpoint_rw import burst_pkg::*; (
  input  logic        clk_i, rst_ni,

  // Read-Burst  (vom Read-Compressor; hdr.we == 0)
  input  burst_req_t  rd_req_i,    // nutzt: hdr, hdr_valid, rready
  output burst_rsp_t  rd_rsp_o,    // nutzt: hdr_gnt, rdata, rvalid

  // Write-Burst (vom Write-Compressor; hdr.we == 1)
  input  burst_req_t  wr_req_i,    // nutzt: hdr, hdr_valid, wdata, wvalid
  output burst_rsp_t  wr_rsp_o,    // nutzt: hdr_gnt, wready, rvalid (Quittung)

  // CPU-OBI (vom Xbar)
  input  logic                   cpu_req_i, cpu_we_i,
  input  logic [AddrWidth-1:0]   cpu_addr_i,
  input  logic [DataWidth-1:0]   cpu_wdata_i,
  input  logic [DataWidth/8-1:0] cpu_be_i,
  output logic                   cpu_gnt_o, cpu_rvalid_o,
  output logic [DataWidth-1:0]   cpu_rdata_o,

  // SRAM (ein Port)
  output logic                   sram_req_o, sram_we_o,
  output logic [AddrWidth-1:0]   sram_addr_o,
  output logic [DataWidth-1:0]   sram_wdata_o,
  output logic [DataWidth/8-1:0] sram_be_o,
  input  logic                   sram_gnt_i,
  input  logic [DataWidth-1:0]   sram_rdata_i
);

// read engine 
typedef enum logic [1:0] {
    R_IDLE,
    R_READ,
    R_DRAIN
} state_t_r;

state_t_r                   r_state_d, r_state_q;
logic [AddrWidth-1:0]     read_addr_d, read_addr_q;
logic [BurstLenWidth-1:0] read_blen_d, read_blen_q;
logic                     rd_rvalid_d, rd_rvalid_q; 

//write engine

typedef enum logic [1:0] {
    W_IDLE,
    W_WRITE
} state_t_w;

state_t_w                   w_state_d, w_state_q;
logic [AddrWidth-1:0]     write_addr_d, write_addr_q;
logic [BurstLenWidth-1:0] write_blen_d, write_blen_q;
logic                     wr_ack_d, wr_ack_q; 

// cpu + arbiter/crossbar 

typedef enum logic [1:0] {
    READ,
    WRITE
} type_t;
logic cpu_rvalid_d, cpu_rvalid_q;
type_t last_d, last_q;


logic rd_grant;
logic rd_want;
logic wr_want;
logic wr_grant;
logic cpu_grant;
logic burst_starting;


////////// read fsm //////////////
always_comb begin
    r_state_d = r_state_q;
    read_addr_d = read_addr_q;
    read_blen_d = read_blen_q;
    rd_rvalid_d = 0;
    rd_rsp_o = '0;
    rd_rsp_o.rvalid = rd_rvalid_q;     
    rd_rsp_o.rdata = sram_rdata_i;  

    case (r_state_q)

        R_IDLE: begin
            if(rd_req_i.hdr_valid)begin
                read_addr_d = rd_req_i.hdr.start_addr;
                read_blen_d = rd_req_i.hdr.blen;
                rd_rsp_o.hdr_gnt = 1;
                r_state_d = R_READ;
            end else begin
                r_state_d = R_IDLE; // useless only for clarity 
            end
        end

        R_READ: begin
            if (sram_gnt_i && rd_grant) begin
                rd_rvalid_d = 1;
                read_addr_d = read_addr_q + 4;
                if (read_blen_q == 0) begin
                    r_state_d = R_DRAIN;
                end else begin
                    read_blen_d = read_blen_q - 1;
                end
            end 
        end

        R_DRAIN: begin
            r_state_d = R_IDLE; 
            end

        default: begin
            r_state_d = R_IDLE;
        end
    endcase
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni)begin
        r_state_q <= R_IDLE;
        read_addr_q <= 32'h0;
        read_blen_q <= 8'd0;
        rd_rvalid_q <= 0;
    end else begin
        r_state_q <= r_state_d;
        read_addr_q <= read_addr_d;
        read_blen_q <= read_blen_d;
        rd_rvalid_q <= rd_rvalid_d;
    end 
end

////////////// write fsm /////////////////// 

always_comb begin
    w_state_d = w_state_q;
    write_addr_d = write_addr_q;
    write_blen_d = write_blen_q;
    wr_rsp_o = '0;
    wr_rsp_o.rvalid = wr_ack_q;
    wr_ack_d = 0;

    case (w_state_q)

        W_IDLE: begin
            if(wr_req_i.hdr_valid)begin 
                write_addr_d = wr_req_i.hdr.start_addr;
                write_blen_d = wr_req_i.hdr.blen;
                wr_rsp_o.hdr_gnt = 1;
                w_state_d = W_WRITE;
            end else begin
                w_state_d = W_IDLE;
            end
        end

        W_WRITE: begin
            if(wr_grant && wr_req_i.wvalid && sram_gnt_i)begin //write data valid 
                wr_rsp_o.wready = 1;
                wr_ack_d = 1; 
                write_addr_d = write_addr_q + 4;
                if(write_blen_q == 0)begin
                    w_state_d = W_IDLE;
                end else begin 
                    write_blen_d = write_blen_q - 1;
                end   
            end 
        end

        default: begin
            w_state_d = W_IDLE;
        end
    endcase
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni)begin
        w_state_q <= W_IDLE;
        write_addr_q <= 32'h0;
        write_blen_q <= 8'd0;
        wr_ack_q <= 0;
    end else begin
        w_state_q <= w_state_d;
        write_addr_q <= write_addr_d;
        write_blen_q <= write_blen_d;
        wr_ack_q <= wr_ack_d;
    end 
end


//////////////////////// arbiter for accessing sram ///////////////////////////////////

assign rd_want = (r_state_q == R_READ);
assign wr_want = (w_state_q == W_WRITE) && wr_req_i.wvalid;
assign burst_starting =
    (r_state_q == R_IDLE && rd_req_i.hdr_valid) ||
    (w_state_q == W_IDLE && wr_req_i.hdr_valid);

always_comb begin
    rd_grant  = 0;
    wr_grant  = 0;
    cpu_grant = 0;
    last_d    = last_q;

    if (rd_want && wr_want) begin
        if (last_q == READ) begin
            wr_grant = 1;
        end else begin
            rd_grant = 1;
        end
    end else if (rd_want) begin
        rd_grant = 1;
    end else if (wr_want) begin
        wr_grant = 1;
    end else if (!burst_starting && r_state_q == R_IDLE && w_state_q == W_IDLE) begin
        cpu_grant = cpu_req_i;
    end

    if (rd_grant && sram_gnt_i) begin
        last_d = READ;
    end else if (wr_grant && sram_gnt_i) begin
        last_d = WRITE;
    end
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni)begin
        last_q <= READ;
    end else begin
        last_q <= last_d;
    end 
end

////////////////////// writing/reading to sram //////////////////////////////// 

always_comb begin
    sram_req_o = 0; 
    sram_we_o = 0; 
    sram_addr_o = 0; 
    sram_wdata_o = 0; 
    sram_be_o = 0;

    if (rd_grant) begin //allowed to read
        sram_req_o = 1; 
        sram_we_o = 0; 
        sram_addr_o = read_addr_q;  
        sram_be_o = '1;
    end else if (wr_grant) begin //allowed to write
        sram_req_o = 1; 
        sram_we_o = 1; 
        sram_addr_o = write_addr_q; 
        sram_wdata_o = wr_req_i.wdata; 
        sram_be_o = '1;
    end else if (cpu_grant) begin //cpu allowed to read/write
        sram_req_o = cpu_req_i; 
        sram_we_o = cpu_we_i; 
        sram_addr_o = cpu_addr_i;
        sram_wdata_o = cpu_wdata_i; 
        sram_be_o = cpu_be_i;
    end
end


always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni)begin
        cpu_rvalid_q <= 0;
    end else begin
        cpu_rvalid_q <= cpu_rvalid_d;
    end 
end

assign cpu_gnt_o    = cpu_grant ? sram_gnt_i : 0;
assign cpu_rvalid_d = cpu_grant && !cpu_we_i && sram_gnt_i;                                          
assign cpu_rvalid_o = cpu_rvalid_q;  
assign cpu_rdata_o = sram_rdata_i;

endmodule
