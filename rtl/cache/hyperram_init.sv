

module hyperram_init #(
    parameter int unsigned AddrWidth = 32,
    parameter logic [AddrWidth-1:0] LogicalBaseAddr = 32'h8000_0000,

    parameter int unsigned InitDataBytes      = 0,
    parameter int unsigned InitBurstDataBytes = 1024,

    parameter type mem_req_t = logic,
    parameter type mem_rsp_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  logic cfg_ready_i,

    output mem_req_t mem_req_o,
    input  mem_rsp_t mem_rsp_i,

    output logic busy_o,
    output logic done_o,
    output logic error_o
);

    localparam unsigned NumbRecordsStandard = InitBurstDataBytes / cache_pkg::CacheRecordDataBytes;
    localparam unsigned NumBursts = (InitBurstDataBytes > 0)
        ? InitDataBytes / InitBurstDataBytes +
          ((InitDataBytes % InitBurstDataBytes != 0) ? 1 : 0)
        : 0;
    localparam unsigned LastBurstDataBytes = (NumBursts > 0)
        ? InitDataBytes - (NumBursts - 1) * InitBurstDataBytes
        : 0;
    localparam unsigned NumbRecordsLast = LastBurstDataBytes / cache_pkg::CacheRecordDataBytes;
    localparam unsigned BurstIndexWidth = (NumBursts > 1) ? $clog2(NumBursts) : 1;


    typedef enum logic [3:0]
    {  
        IDLE,
        SEND_WRITE_CMD,
        SEND_WRITE_DATA,
        WAIT_WRITE_DONE,
        ERROR,
        DONE
        

    } state_t;

    state_t state_q, state_d;

    logic [AddrWidth-1:0] addr_d, addr_q;
    logic [BurstIndexWidth-1:0] burst_index_q, burst_index_d;

    logic [$clog2(NumbRecordsStandard)-1: 0] record_index_q, record_index_d;

    logic last_burst;
    logic last_record;



    assign last_burst = (burst_index_q == NumBursts -1);

    assign last_record = (last_burst && record_index_q == NumbRecordsLast-1) 
            || (!last_burst && record_index_q == NumbRecordsStandard-1);

    
    always_comb begin

        state_d = state_q;
        addr_d = addr_q;
        burst_index_d = burst_index_q;
        record_index_d = record_index_q;
        
        mem_req_o = '0;

        busy_o = 0;
        done_o = 0;
        error_o = 0;


        case (state_q)

            IDLE: begin
                if (cfg_ready_i) begin //hyperram config done
                    addr_d = LogicalBaseAddr;
                    burst_index_d = '0;
                    state_d = SEND_WRITE_CMD;
                end
                
            end

            SEND_WRITE_CMD: begin
                busy_o = 1;
                mem_req_o.cmd.write = 1;
                mem_req_o.cmd.line_addr = addr_q;
                if (burst_index_q == BurstIndexWidth'(NumBursts - 1)) begin
                    mem_req_o.cmd.records = NumbRecordsLast;
                end else begin
                    mem_req_o.cmd.records = NumbRecordsStandard;
                end
                mem_req_o.cmd_valid = 1;

                if (mem_rsp_i.cmd_ready && mem_req_o.cmd_valid) begin
                    record_index_d = 0;
                    state_d = SEND_WRITE_DATA;
                end
            end

            SEND_WRITE_DATA: begin

                busy_o = 1;
                mem_req_o.w_valid = 1;
                mem_req_o.w_strb = '1;
                mem_req_o.w.record.lower.data = 0;
                mem_req_o.w.record.lower.cap_tag = 0;
                mem_req_o.w.record.lower.ecc = ibex_mem_ecc_pkg::MemEccZeroEcc;
                mem_req_o.w.record.upper.data = 0;
                mem_req_o.w.record.upper.cap_tag = 0;
                mem_req_o.w.record.upper.ecc = ibex_mem_ecc_pkg::MemEccZeroEcc;

                if (last_record) begin
                    mem_req_o.w.last = 1;
                end 

                if (mem_req_o.w_valid && mem_rsp_i.w_ready) begin
                    if (last_record) begin
                        state_d = WAIT_WRITE_DONE;
                    end
                    else begin
                        record_index_d = record_index_q + 1;
                    end
                end 
            end

            WAIT_WRITE_DONE: begin
                busy_o = 1;
                mem_req_o.done_ready = 1;

                if (mem_rsp_i.done_valid && mem_req_o.done_ready) begin
                    if (mem_rsp_i.done.error) begin
                        state_d = ERROR;
                    end else begin
                        if (last_burst) begin
                            state_d = DONE;
                        end
                        else begin
                            burst_index_d = burst_index_q + 1;
                            addr_d = addr_q + InitBurstDataBytes;
                            state_d = SEND_WRITE_CMD;
                        end
                    end 
                end
            
                
            end

            ERROR: begin
                error_o = 1;
            end
            
            DONE: begin
                done_o = 1;
            end
            
            default: begin
                state_d = IDLE;

            end
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= IDLE;
            addr_q <= LogicalBaseAddr;
            burst_index_q <= '0;
            record_index_q <= 0;
        end else begin
            state_q <= state_d;
            addr_q <= addr_d;
            burst_index_q <= burst_index_d;
            record_index_q <= record_index_d;
        end 
    end

    `include "hyperram_init_param_checks.svh"

endmodule
