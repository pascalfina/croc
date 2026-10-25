
module obi_to_reg #(
    parameter type obi_req_t = logic,
    parameter type obi_rsp_t = logic,
    parameter type reg_req_t = logic,
    parameter type reg_rsp_t = logic,
    parameter int unsigned ObiAddrWidth = 32,
    parameter int unsigned ObiDataWidth = 32,
    parameter int unsigned ObiIdWidth = 4,
    parameter logic [31:0] RegBaseAddr = 32'h0300_C000
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  obi_req_t obi_req_i,
    output obi_rsp_t obi_rsp_o,

    output  reg_req_t reg_req_o,
    input reg_rsp_t reg_rsp_i
);

generate
    if (ObiDataWidth != 32) begin : gen_invalid_data_width
        $error("OBI-to-register adapter supports only 32-bit data.");
    end

    if (ObiAddrWidth != 32) begin : gen_invalid_addr_width
        $error("OBI-to-register adapter supports only 32-bit addresses.");
    end

    if ($bits(obi_req_i.a.addr)  != ObiAddrWidth ||
        $bits(obi_req_i.a.wdata) != ObiDataWidth ||
        $bits(obi_rsp_o.r.rdata) != ObiDataWidth) begin : gen_invalid_obi_fields
        $error("OBI struct widths do not match the configured parameters.");
    end

    if (ObiIdWidth < 1 ||
        $bits(obi_req_i.a.aid) != ObiIdWidth ||
        $bits(obi_rsp_o.r.rid) != ObiIdWidth) begin : gen_invalid_id_width
        $error("OBI request and response ID widths must match ObiIdWidth.");
    end

    if ($bits(reg_req_o.addr)  != 32 ||
        $bits(reg_req_o.wdata) != 32 ||
        $bits(reg_rsp_i.rdata) != 32) begin : gen_invalid_reg_fields
        $error("Register bus address and data fields must each be 32 bits wide.");
    end

    if ($bits(obi_req_i.a.be)  != 4 ||
        $bits(reg_req_o.wstrb) != 4) begin : gen_invalid_byte_masks
        $error("OBI byte enable and register write strobe must each be 4 bits wide.");
    end
endgenerate

typedef enum logic [1:0] {
    IDLE,
    WAIT
} state_t;

state_t state_q, state_d;

logic obi_we_q, obi_we_d;
logic [3:0] obi_be_q, obi_be_d;
logic [ObiDataWidth-1:0] obi_wdata_q, obi_wdata_d;
logic [ObiIdWidth-1:0] obi_aid_q, obi_aid_d; 

logic [31:0] offset;
logic [31:0] reg_offset_q, reg_offset_d;


assign offset = obi_req_i.a.addr - RegBaseAddr;

// during wait 
assign reg_req_o.addr  = reg_offset_q;
assign reg_req_o.write = obi_we_q;
assign reg_req_o.wdata = obi_wdata_q;
assign reg_req_o.wstrb = obi_be_q;

// during when eg_rsp_i.ready
assign obi_rsp_o.r.rdata = reg_rsp_i.rdata;
assign obi_rsp_o.r.err = reg_rsp_i.error;
assign obi_rsp_o.r.rid = obi_aid_q;

// no tag 
assign obi_rsp_o.r.r_optional = 1'b0;


always_comb begin

    state_d = state_q;

    obi_wdata_d = obi_wdata_q;
    obi_we_d = obi_we_q;
    obi_be_d = obi_be_q;
    reg_offset_d = reg_offset_q;
    obi_aid_d = obi_aid_q;


    obi_rsp_o.gnt = 0;
    reg_req_o.valid = 0;
    obi_rsp_o.rvalid = 0;


    case (state_q)
        IDLE: begin
            obi_rsp_o.gnt = 1;

            if (obi_rsp_o.gnt && obi_req_i.req) begin
                obi_wdata_d = obi_req_i.a.wdata;
                obi_be_d = obi_req_i.a.be;
                obi_we_d = obi_req_i.a.we;
                reg_offset_d = offset;
                obi_aid_d = obi_req_i.a.aid;
                state_d = WAIT;
            end
        end

        WAIT: begin
            reg_req_o.valid = 1;
            
            if (reg_req_o.valid && reg_rsp_i.ready) begin
                obi_rsp_o.rvalid = 1; // when reg ready read data from hyperbus controller also ready 
                state_d = IDLE;  
            end
            
        end
        
        default: begin
            state_d = IDLE;
        end
    endcase
    
end

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        state_q <= IDLE;
        obi_wdata_q <= 0;
        obi_we_q <= 0;
        obi_be_q <= 0;
        reg_offset_q <= 0;
        obi_aid_q <= 0;
    end
    else begin
        state_q <= state_d;
        obi_wdata_q <= obi_wdata_d;
        obi_we_q <= obi_we_d;
        obi_be_q <= obi_be_d;
        reg_offset_q <= reg_offset_d;
        obi_aid_q <= obi_aid_d;
    end
    
end
    
endmodule
